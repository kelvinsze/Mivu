import Foundation
import Network
import UIKit
import OSLog

private let logger = Logger(subsystem: "com.kold.mivu", category: "HTTPServer")

/// Embedded lightweight HTTP & REST / Web Remote server using Network.framework.
public final class HTTPServer: @unchecked Sendable {
    public static let shared = HTTPServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.kold.mivu.httpserver", qos: .userInitiated)
    public private(set) var isRunning = false
    public private(set) var port: UInt16 = 7890

    private static let maximumUploadSize = 10 * 1024 * 1024 * 1024
    private static let maximumHeaderSize = 32 * 1024
    private static let maximumControlRequestSize = 1 * 1024 * 1024
    public let webAccessCode: String

    public var localIPAddress: String {
        return NetworkHelper.getWiFiAddress() ?? "127.0.0.1"
    }

    private init() {
        webAccessCode = String(format: "%06d", Int.random(in: 0..<1_000_000))
    }

    public func start(port: UInt16 = 7890) {
        guard !isRunning else { return }
        self.port = port
        UPnPDevice.shared.serverPort = port

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                logger.error("Invalid port: \(port)")
                return
            }

            let newListener = try NWListener(using: parameters, on: nwPort)
            newListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.isRunning = true
                    logger.info("Mivu HTTP Server listening on port \(port). IP: \(self?.localIPAddress ?? "unknown")")
                case .failed(let error):
                    logger.error("HTTP Server listener failed: \(error.localizedDescription)")
                    self?.isRunning = false
                case .cancelled:
                    self?.isRunning = false
                default:
                    break
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleIncomingConnection(connection)
            }

            newListener.start(queue: queue)
            self.listener = newListener
        } catch {
            logger.error("Failed to start HTTP server: \(error.localizedDescription)")
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        logger.info("HTTP Server stopped.")
    }

    private func handleIncomingConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHTTPRequest(connection: connection, accumulatedData: Data())
    }

    private func readHTTPRequest(connection: NWConnection, accumulatedData: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            var currentData = accumulatedData
            if let content = content {
                currentData.append(content)
            }

            guard currentData.count <= Self.maximumHeaderSize || currentData.range(of: Data("\r\n\r\n".utf8)) != nil else {
                self.sendResponse(connection: connection, statusCode: 431, contentType: "text/plain", body: "Request Header Fields Too Large")
                return
            }

            // Check if headers are completely received
            if let headerEndRange = currentData.range(of: Data("\r\n\r\n".utf8)) {
                guard headerEndRange.lowerBound <= Self.maximumHeaderSize else {
                    self.sendResponse(connection: connection, statusCode: 431, contentType: "text/plain", body: "Request Header Fields Too Large")
                    return
                }
                let headerData = currentData.subdata(in: 0..<headerEndRange.lowerBound)
                let bodyData = currentData.subdata(in: headerEndRange.upperBound..<currentData.count)

                guard let headerString = String(data: headerData, encoding: .utf8) else {
                    self.sendResponse(connection: connection, statusCode: 400, contentType: "text/plain", body: "Bad Request")
                    return
                }

                let headers = self.parseHeaders(headerString)
                let contentLength = Int(headers["content-length"] ?? "0") ?? 0

                guard contentLength >= 0 else {
                    self.sendResponse(connection: connection, statusCode: 400, contentType: "text/plain", body: "Bad Request")
                    return
                }

                if self.isUploadRequest(headerString: headerString) {
                    self.receiveUpload(
                        connection: connection,
                        headerString: headerString,
                        headers: headers,
                        initialBodyData: bodyData,
                        contentLength: contentLength
                    )
                } else if contentLength > Self.maximumControlRequestSize {
                    self.sendResponse(connection: connection, statusCode: 413, contentType: "application/json", body: "{\"error\":\"payload_too_large\"}")
                } else if bodyData.count >= contentLength {
                    self.processRequest(connection: connection, headerString: headerString, headers: headers, bodyData: bodyData)
                } else {
                    // Read more body data
                    self.readHTTPRequest(connection: connection, accumulatedData: currentData)
                }
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                // Continue reading headers
                self.readHTTPRequest(connection: connection, accumulatedData: currentData)
            }
        }
    }

    private func isUploadRequest(headerString: String) -> Bool {
        let requestLine = headerString.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return false }
        let path = String(parts[1].split(separator: "?", maxSplits: 1).first ?? "")
        return parts[0].uppercased() == "POST" && path == "/api/upload"
    }

    /// Saves upload bodies incrementally so large videos never need to be held in memory.
    private func receiveUpload(
        connection: NWConnection,
        headerString: String,
        headers: [String: String],
        initialBodyData: Data,
        contentLength: Int
    ) {
        guard isAuthorizedWebRequest(headers: headers) else {
            sendResponse(connection: connection, statusCode: 401, contentType: "application/json", body: "{\"error\":\"access_code_required\"}")
            return
        }

        guard contentLength > 0, contentLength <= Self.maximumUploadSize else {
            sendResponse(connection: connection, statusCode: 413, contentType: "application/json", body: "{\"error\":\"file_too_large\"}")
            return
        }

        let requestTarget = headerString.components(separatedBy: "\r\n").first?
            .split(separator: " ")
            .dropFirst()
            .first
            .map(String.init) ?? ""
        let providedName = URLComponents(string: "http://localhost\(requestTarget)")?
            .queryItems?
            .first(where: { $0.name == "filename" })?
            .value ?? ""

        guard UploadedVideoStore.isSupportedVideo(filename: providedName),
              headers["content-type"]?.lowercased().hasPrefix("video/") != false else {
            sendResponse(connection: connection, statusCode: 415, contentType: "application/json", body: "{\"error\":\"unsupported_video\"}")
            return
        }
        guard initialBodyData.count <= contentLength else {
            sendResponse(connection: connection, statusCode: 400, contentType: "application/json", body: "{\"error\":\"invalid_body\"}")
            return
        }

        do {
            let destination = try UploadedVideoStore.uniqueDestination(for: providedName)
            let temporaryURL = destination.deletingLastPathComponent()
                .appendingPathComponent(".upload-\(UUID().uuidString.lowercased())")
            FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: temporaryURL)
            handle.write(initialBodyData)

            if initialBodyData.count == contentLength {
                finishUpload(connection: connection, handle: handle, temporaryURL: temporaryURL, destination: destination)
            } else {
                receiveUploadChunk(
                    connection: connection,
                    handle: handle,
                    temporaryURL: temporaryURL,
                    destination: destination,
                    receivedBytes: initialBodyData.count,
                    contentLength: contentLength
                )
            }
        } catch {
            logger.error("Unable to prepare upload: \(error.localizedDescription)")
            sendResponse(connection: connection, statusCode: 500, contentType: "application/json", body: "{\"error\":\"storage_unavailable\"}")
        }
    }

    private func receiveUploadChunk(
        connection: NWConnection,
        handle: FileHandle,
        temporaryURL: URL,
        destination: URL,
        receivedBytes: Int,
        contentLength: Int
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            guard error == nil, let content else {
                try? handle.close()
                try? FileManager.default.removeItem(at: temporaryURL)
                if error == nil && !isComplete {
                    self.sendResponse(connection: connection, statusCode: 400, contentType: "application/json", body: "{\"error\":\"incomplete_upload\"}")
                }
                return
            }

            let totalBytes = receivedBytes + content.count
            guard totalBytes <= contentLength else {
                try? handle.close()
                try? FileManager.default.removeItem(at: temporaryURL)
                self.sendResponse(connection: connection, statusCode: 400, contentType: "application/json", body: "{\"error\":\"invalid_body\"}")
                return
            }

            handle.write(content)
            if totalBytes == contentLength {
                self.finishUpload(connection: connection, handle: handle, temporaryURL: temporaryURL, destination: destination)
            } else if isComplete {
                try? handle.close()
                try? FileManager.default.removeItem(at: temporaryURL)
                self.sendResponse(connection: connection, statusCode: 400, contentType: "application/json", body: "{\"error\":\"incomplete_upload\"}")
            } else {
                self.receiveUploadChunk(
                    connection: connection,
                    handle: handle,
                    temporaryURL: temporaryURL,
                    destination: destination,
                    receivedBytes: totalBytes,
                    contentLength: contentLength
                )
            }
        }
    }

    private func finishUpload(connection: NWConnection, handle: FileHandle, temporaryURL: URL, destination: URL) {
        do {
            try handle.close()
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            logger.info("Saved Wi-Fi upload: \(destination.lastPathComponent, privacy: .public)")

            Task { @MainActor in
                NotificationCenter.default.post(name: .mivuUploadedVideosDidChange, object: destination)
            }
            sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: "{\"status\":\"ok\"}")
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            logger.error("Unable to save upload: \(error.localizedDescription)")
            sendResponse(connection: connection, statusCode: 500, contentType: "application/json", body: "{\"error\":\"save_failed\"}")
        }
    }

    private func parseHeaders(_ rawHeader: String) -> [String: String] {
        var headers: [String: String] = [:]
        let lines = rawHeader.components(separatedBy: "\r\n")
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                headers[parts[0].lowercased()] = parts[1]
            }
        }
        return headers
    }

    private func requiresWebAccess(path: String) -> Bool {
        path == "/debug/carplay" || path.hasPrefix("/api/")
    }

    private func isAuthorizedWebRequest(headers: [String: String]) -> Bool {
        headers["x-mivu-access-code"]?.trimmingCharacters(in: .whitespacesAndNewlines) == webAccessCode
    }

    private func processRequest(connection: NWConnection, headerString: String, headers: [String: String], bodyData: Data) {
        let firstLine = headerString.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendResponse(connection: connection, statusCode: 400, contentType: "text/plain", body: "Bad Request")
            return
        }

        let method = String(parts[0]).uppercased()
        let requestTarget = String(parts[1])
        let path = String(requestTarget.split(separator: "?", maxSplits: 1).first ?? "")
        let discoveryHint = URLComponents(string: "http://localhost\(requestTarget)")?
            .queryItems?
            .first(where: { $0.name == "via" })?
            .value
        logger.info("HTTP Request: \(method) \(requestTarget)")

        if requiresWebAccess(path: path), !isAuthorizedWebRequest(headers: headers) {
            sendResponse(connection: connection, statusCode: 401, contentType: "application/json", body: "{\"error\":\"access_code_required\"}")
            return
        }

        switch (method, path) {
        // MARK: - UPnP Device Description & SCPD
        case ("GET", "/description.xml"):
            SSDPService.shared.recordHTTPStage(
                "description.xml",
                remoteEndpoint: connection.currentPath?.remoteEndpoint,
                discoveryHint: discoveryHint
            )
            let xml = UPnPDevice.shared.deviceDescriptionXML(hostIP: localIPAddress)
            sendResponse(connection: connection, statusCode: 200, contentType: "text/xml; charset=\"utf-8\"", body: xml)

        case ("GET", "/avtransport.xml"):
            SSDPService.shared.recordHTTPStage("avtransport.xml", remoteEndpoint: connection.currentPath?.remoteEndpoint)
            let xml = UPnPDevice.shared.avTransportSCPD()
            sendResponse(connection: connection, statusCode: 200, contentType: "text/xml; charset=\"utf-8\"", body: xml)

        case ("GET", "/renderingcontrol.xml"):
            SSDPService.shared.recordHTTPStage("renderingcontrol.xml", remoteEndpoint: connection.currentPath?.remoteEndpoint)
            let xml = UPnPDevice.shared.renderingControlSCPD()
            sendResponse(connection: connection, statusCode: 200, contentType: "text/xml; charset=\"utf-8\"", body: xml)

        case ("GET", "/connectionmanager.xml"):
            SSDPService.shared.recordHTTPStage("connectionmanager.xml", remoteEndpoint: connection.currentPath?.remoteEndpoint)
            let xml = UPnPDevice.shared.connectionManagerSCPD()
            sendResponse(connection: connection, statusCode: 200, contentType: "text/xml; charset=\"utf-8\"", body: xml)

        // MARK: - UPnP Control (SOAP)
        case ("POST", let p) where p.hasPrefix("/upnp/control/"):
            let soapActionHeader = headers["soapaction"]
            if let action = SOAPParser.parseAction(bodyData: bodyData, soapActionHeader: soapActionHeader) {
                SSDPService.shared.recordHTTPStage(action.actionName, remoteEndpoint: connection.currentPath?.remoteEndpoint)
                Task {
                    let result = await AVTransportService.shared.handleRequest(action: action)
                    self.sendResponse(connection: connection, statusCode: result.statusCode, contentType: "text/xml; charset=\"utf-8\"", body: result.responseBody)
                }
            } else {
                let fault = SOAPParser.makeSOAPFault(errorCode: 401, errorDescription: "Invalid Action")
                sendResponse(connection: connection, statusCode: 500, contentType: "text/xml; charset=\"utf-8\"", body: fault)
            }

        // MARK: - CarPlay Diagnostics Endpoint
        case ("GET", "/debug/carplay"):
            Task { @MainActor in
                let scenes = UIApplication.shared.connectedScenes.map { scene -> [String: Any] in
                    return [
                        "role": scene.session.role.rawValue,
                        "class": String(describing: type(of: scene)),
                        "delegate": String(describing: type(of: scene.delegate ?? nil)),
                        "activationState": scene.activationState.rawValue
                    ]
                }
                let cpDelegate = CarPlaySceneDelegate.shared
                let isConn = cpDelegate?.isConnected ?? false
                let hasInterface = cpDelegate?.interfaceController != nil
                let hasRoot = cpDelegate?.rootTemplate != nil
                let videoAvail = cpDelegate?.isVideoPlaybackAvailable ?? false
                let systemVideoAvail = cpDelegate?.isSystemVideoPlaybackAvailable ?? false
                let sectionsCount = cpDelegate?.rootTemplate?.sections.count ?? 0

                let json: [String: Any] = [
                    "connectedScenes": scenes,
                    "carPlayDelegateShared": cpDelegate != nil,
                    "isConnected": isConn,
                    "hasInterfaceController": hasInterface,
                    "hasRootTemplate": hasRoot,
                    "rootTemplateSectionsCount": sectionsCount,
                    "isVideoPlaybackAvailable": videoAvail,
                    "isSystemVideoPlaybackAvailable": systemVideoAvail,
                    "playerStatus": PlayerService.shared.session.status.rawValue,
                    "hasCurrentItem": PlayerService.shared.session.currentItem?.title ?? "none"
                ]
                if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
                   let str = String(data: data, encoding: .utf8) {
                    self.sendResponse(connection: connection, statusCode: 200, contentType: "application/json; charset=\"utf-8\"", body: str)
                } else {
                    self.sendResponse(connection: connection, statusCode: 500, contentType: "text/plain", body: "error")
                }
            }

        // MARK: - REST API for Local Web Remote & Diagnostics
        case ("GET", "/api/status"):
            Task {
                let (session, mpvRenderDiagnostic, carPlayConnected, carPlayVideo, carPlaySections) = await MainActor.run {
                    (
                        PlayerService.shared.session,
                        PlayerService.shared.activeMPVRenderDiagnostic ?? "",
                        CarPlaySceneDelegate.shared?.isConnected ?? false,
                        CarPlaySceneDelegate.shared?.isVideoPlaybackAvailable ?? false,
                        CarPlaySceneDelegate.shared?.rootTemplate?.sections.count ?? 0
                    )
                }
                let responseDict: [String: Any] = [
                    "status": session.status.rawValue,
                    "title": session.currentItem?.title ?? "",
                    "url": session.currentItem?.url.absoluteString ?? "",
                    "currentTime": session.currentTime,
                    "duration": session.duration,
                    "volume": session.volume,
                    "isMuted": session.isMuted,
                    "ip": self.localIPAddress,
                    "port": self.port,
                    "friendlyName": UPnPDevice.shared.friendlyName,
                    "mpvRenderDiagnostic": mpvRenderDiagnostic,
                    "carPlayConnected": carPlayConnected,
                    "carPlayVideoAvailable": carPlayVideo,
                    "carPlayRootSections": carPlaySections
                ]
                if let jsonData = try? JSONSerialization.data(withJSONObject: responseDict, options: [.prettyPrinted]),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    self.sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: jsonString)
                } else {
                    self.sendResponse(connection: connection, statusCode: 500, contentType: "application/json", body: "{\"error\":\"json_encoding_failed\"}")
                }
            }

        case ("GET", "/api/logs"):
            SSDPService.shared.requestDiagnosticHistory { logs in
                if let jsonData = try? JSONSerialization.data(withJSONObject: logs, options: [.prettyPrinted]),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    self.sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: jsonString)
                } else {
                    self.sendResponse(connection: connection, statusCode: 500, contentType: "application/json", body: "{\"error\":\"json_encoding_failed\"}")
                }
            }

        case ("POST", "/api/play"):
            if let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
               let urlStr = json["url"] as? String,
               let url = URL(string: urlStr),
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                let title = (json["title"] as? String) ?? url.lastPathComponent
                let item = MediaItem(
                    title: title.isEmpty ? "Web Stream" : title,
                    url: url,
                    sourceType: .directUrl,
                    originator: "Web Remote"
                )
                Task { @MainActor in
                    PlayerService.shared.loadAndPlay(item: item)
                    PlayerService.shared.isShowingPlayer = true
                }
                sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: "{\"status\":\"ok\"}")
            } else {
                sendResponse(connection: connection, statusCode: 400, contentType: "application/json", body: "{\"error\":\"invalid_payload\"}")
            }

        case ("POST", "/api/control"):
            if let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
               let action = json["action"] as? String {
                Task { @MainActor in
                    switch action {
                    case "play": PlayerService.shared.play()
                    case "pause": PlayerService.shared.pause()
                    case "stop": PlayerService.shared.stop()
                    case "toggle": PlayerService.shared.togglePlayPause()
                    case "seek":
                        if let time = json["value"] as? Double {
                            PlayerService.shared.seek(to: time)
                        }
                    case "volume":
                        if let vol = json["value"] as? Float {
                            PlayerService.shared.setVolume(vol)
                        }
                    default: break
                    }
                }
                sendResponse(connection: connection, statusCode: 200, contentType: "application/json", body: "{\"status\":\"ok\"}")
            } else {
                sendResponse(connection: connection, statusCode: 400, contentType: "application/json", body: "{\"error\":\"invalid_payload\"}")
            }

        // MARK: - Web Remote Controller HTML UI
        case ("GET", "/"), ("GET", "/web"):
            let html = WebRemoteTemplate.render(ip: localIPAddress, port: port, friendlyName: UPnPDevice.shared.friendlyName)
            sendResponse(connection: connection, statusCode: 200, contentType: "text/html; charset=utf-8", body: html)

        default:
            sendResponse(connection: connection, statusCode: 404, contentType: "text/plain", body: "Not Found")
        }
    }

    private func sendResponse(connection: NWConnection, statusCode: Int, contentType: String, body: String) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 413: statusText = "Payload Too Large"
        case 415: statusText = "Unsupported Media Type"
        case 431: statusText = "Request Header Fields Too Large"
        default: statusText = "Internal Server Error"
        }
        let bodyData = Data(body.utf8)
        let responseHeader = """
        HTTP/1.1 \(statusCode) \(statusText)\r
        Server: iOS/17 UPnP/1.0 Mivu/0.1\r
        Content-Type: \(contentType)\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r\n
        """

        var fullData = Data(responseHeader.utf8)
        fullData.append(bodyData)

        connection.send(content: fullData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendResponseWithCustomHeaders(connection: NWConnection, statusCode: Int, headers: [String: String], body: String) {
        let statusText = "OK"
        let bodyData = Data(body.utf8)
        var headerString = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        for (key, val) in headers {
            headerString += "\(key): \(val)\r\n"
        }
        headerString += "Content-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"

        var fullData = Data(headerString.utf8)
        fullData.append(bodyData)

        connection.send(content: fullData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// MARK: - Embedded Web Remote HTML Template

enum WebRemoteTemplate {
    static func render(ip: String, port: UInt16, friendlyName: String) -> String {
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
          <title>Mivu Web Remote</title>
          <style>
            :root {
              --bg: #0b0f19;
              --card: #151d30;
              --accent: #38bdf8;
              --text: #f8fafc;
              --muted: #94a3b8;
            }
            * { box-sizing: border-box; margin: 0; padding: 0; }
            body {
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
              background-color: var(--bg);
              color: var(--text);
              padding: 1.25rem;
              display: flex;
              justify-content: center;
            }
            .app-container {
              width: 100%;
              max-width: 480px;
            }
            header {
              text-align: center;
              margin-bottom: 1.5rem;
            }
            h1 { font-size: 1.5rem; color: var(--accent); }
            .badge {
              font-size: 0.8rem;
              background: rgba(56,189,248,0.15);
              color: var(--accent);
              padding: 0.2rem 0.6rem;
              border-radius: 999px;
              margin-top: 0.25rem;
              display: inline-block;
            }
            .card {
              background: var(--card);
              border-radius: 1rem;
              padding: 1.25rem;
              margin-bottom: 1.25rem;
              border: 1px solid rgba(255,255,255,0.06);
            }
            .card-title {
              font-size: 0.95rem;
              font-weight: 600;
              color: var(--muted);
              margin-bottom: 0.75rem;
            }
            input[type="text"], input[type="password"] {
              width: 100%;
              padding: 0.75rem 1rem;
              background: rgba(0,0,0,0.3);
              border: 1px solid rgba(255,255,255,0.1);
              border-radius: 0.5rem;
              color: #fff;
              font-size: 0.9rem;
              margin-bottom: 0.75rem;
            }
            input[type="file"] {
              width: 100%;
              color: var(--muted);
              margin-bottom: 0.75rem;
            }
            progress {
              width: 100%;
              height: 0.45rem;
              margin-top: 0.8rem;
              accent-color: var(--accent);
            }
            .upload-status {
              font-size: 0.82rem;
              color: var(--muted);
              margin-top: 0.5rem;
              min-height: 1rem;
            }
            button.btn-primary {
              width: 100%;
              background: var(--accent);
              color: #0b0f19;
              font-weight: 600;
              border: none;
              padding: 0.75rem;
              border-radius: 0.5rem;
              cursor: pointer;
              font-size: 0.95rem;
            }
            .controls-row {
              display: flex;
              gap: 0.75rem;
              margin-top: 0.75rem;
            }
            .btn-ctrl {
              flex: 1;
              background: rgba(255,255,255,0.08);
              border: 1px solid rgba(255,255,255,0.1);
              color: #fff;
              padding: 0.75rem;
              border-radius: 0.5rem;
              font-weight: 600;
              cursor: pointer;
            }
            .btn-ctrl:active, button.btn-primary:active { opacity: 0.7; }
            .status-text {
              font-size: 0.9rem;
              margin-bottom: 0.4rem;
            }
            .time-bar {
              font-family: monospace;
              font-size: 0.85rem;
              color: var(--muted);
            }
          </style>
        </head>
        <body>
          <div class="app-container">
            <header>
              <h1 data-i18n="heading">Mivu Remote & Casting</h1>
              <div class="badge">\(friendlyName)</div>
            </header>

            <div class="card">
              <div class="card-title" data-i18n="accessTitle">Access Code</div>
              <input type="password" id="accessCodeInput" inputmode="numeric" autocomplete="one-time-code" maxlength="6" data-i18n-placeholder="accessPlaceholder" placeholder="Enter the 6-digit code shown in Mivu">
              <button class="btn-primary" onclick="unlockWebRemote()" data-i18n="unlock">Unlock Remote</button>
              <div class="upload-status" id="accessCodeStatus" data-i18n="accessHint">Enter the code from Mivu to control or upload.</div>
            </div>

            <div class="card">
              <div class="card-title" data-i18n="nowPlaying">Now Playing</div>
              <div class="status-text" id="mediaTitle" data-i18n="loading">Loading...</div>
              <div class="time-bar" id="mediaTime">00:00:00 / 00:00:00</div>
              <div class="controls-row">
                <button class="btn-ctrl" onclick="sendControl('toggle')" data-i18n="toggle">⏯ Play/Pause</button>
                <button class="btn-ctrl" onclick="sendControl('stop')" data-i18n="stop">⏹ Stop</button>
              </div>
            </div>

            <div class="card">
              <div class="card-title" data-i18n="pushTitle">Send a video URL to CarPlay / Mivu</div>
              <input type="text" id="videoUrlInput" data-i18n-placeholder="urlPlaceholder" placeholder="Enter an HTTP/HTTPS or HLS m3u8 URL">
              <button class="btn-primary" onclick="pushVideo()" data-i18n="push">🚀 Play on Mivu</button>
            </div>

            <div class="card">
              <div class="card-title" data-i18n="uploadTitle">Upload to Mivu over Wi-Fi</div>
              <input type="file" id="videoFileInput" accept="video/*,.mkv,.webm,.avi,.m2ts,.ts">
              <button class="btn-primary" id="uploadButton" onclick="uploadVideo()" data-i18n="upload">⬆️ Upload to Library</button>
              <progress id="uploadProgress" value="0" max="100" hidden></progress>
              <div class="upload-status" id="uploadStatus" data-i18n="uploadHint">Videos are saved to this device's Mivu library.</div>
            </div>
          </div>

          <script>
            const locale = (navigator.language || 'en').toLowerCase();
            const language = locale.startsWith('zh') ? ((locale.includes('hant') || /zh-(tw|hk|mo)/.test(locale)) ? 'zh-Hant' : 'zh-Hans') : locale.startsWith('fr') ? 'fr' : locale.startsWith('de') ? 'de' : locale.startsWith('es') ? 'es' : locale.startsWith('pt') ? 'pt-BR' : 'en';
            const messages = {
              en: { heading:'Mivu Remote & Casting', nowPlaying:'Now Playing', loading:'Loading...', toggle:'⏯ Play/Pause', stop:'⏹ Stop', pushTitle:'Send a video URL to CarPlay / Mivu', urlPlaceholder:'Enter an HTTP/HTTPS or HLS m3u8 URL', push:'🚀 Play on Mivu', uploadTitle:'Upload to Mivu over Wi-Fi', upload:'⬆️ Upload to Library', uploadHint:"Videos are saved to this device's Mivu library.", playing:'Playing video', noMedia:'No media', enterURL:'Enter a video URL', chooseFile:'Choose a video file', uploading:'Uploading', uploaded:'Upload complete. Saved to the Mivu library.', failed:'Upload failed. Use a supported video under 10 GB.', offline:'Connection lost. Upload incomplete.', preparing:'Preparing upload…' },
              'zh-Hans': { heading:'Mivu 遥控与投送', nowPlaying:'当前播放', loading:'加载中...', toggle:'⏯ 播放/暂停', stop:'⏹ 停止', pushTitle:'推送视频 URL 到 CarPlay / Mivu', urlPlaceholder:'输入 HTTP/HTTPS 或 HLS m3u8 链接', push:'🚀 立即投送播放', uploadTitle:'通过 Wi-Fi 上传到 Mivu', upload:'⬆️ 上传到视频库', uploadHint:'视频会保存在此设备的 Mivu 文件库中。', playing:'正在播放视频', noMedia:'无媒体', enterURL:'请输入视频链接', chooseFile:'请选择视频文件', uploading:'正在上传', uploaded:'上传完成，已保存到 Mivu 视频库。', failed:'上传失败，请确认文件受支持且小于 10 GB。', offline:'网络连接中断，上传未完成。', preparing:'正在准备上传…' },
              'zh-Hant': { heading:'Mivu 遙控與投放', nowPlaying:'目前播放', loading:'載入中...', toggle:'⏯ 播放/暫停', stop:'⏹ 停止', pushTitle:'傳送影片 URL 至 CarPlay / Mivu', urlPlaceholder:'輸入 HTTP/HTTPS 或 HLS m3u8 連結', push:'🚀 立即投放播放', uploadTitle:'透過 Wi-Fi 上傳至 Mivu', upload:'⬆️ 上傳至媒體庫', uploadHint:'影片會儲存在此裝置的 Mivu 媒體庫。', playing:'正在播放影片', noMedia:'沒有媒體', enterURL:'請輸入影片連結', chooseFile:'請選擇影片檔案', uploading:'正在上傳', uploaded:'上傳完成，已儲存至 Mivu 媒體庫。', failed:'上傳失敗，請確認檔案格式受支援且小於 10 GB。', offline:'網路連線中斷，上傳未完成。', preparing:'正在準備上傳…' },
              fr: { heading:'Télécommande et diffusion Mivu', nowPlaying:'Lecture en cours', loading:'Chargement…', toggle:'⏯ Lecture/Pause', stop:'⏹ Arrêter', pushTitle:'Envoyer une URL vidéo vers CarPlay / Mivu', urlPlaceholder:'Saisissez une URL HTTP/HTTPS ou HLS m3u8', push:'🚀 Lire sur Mivu', uploadTitle:'Importer sur Mivu via Wi-Fi', upload:'⬆️ Importer dans la bibliothèque', uploadHint:'Les vidéos sont enregistrées dans la bibliothèque Mivu de cet appareil.', playing:'Lecture vidéo', noMedia:'Aucun média', enterURL:'Saisissez une URL vidéo', chooseFile:'Choisissez un fichier vidéo', uploading:'Importation', uploaded:'Importation terminée. Vidéo enregistrée dans la bibliothèque Mivu.', failed:'Échec de l’importation. Utilisez une vidéo compatible de moins de 10 Go.', offline:'Connexion interrompue. Importation incomplète.', preparing:'Préparation de l’importation…' },
              de: { heading:'Mivu Fernbedienung & Übertragung', nowPlaying:'Wiedergabe', loading:'Wird geladen…', toggle:'⏯ Wiedergabe/Pause', stop:'⏹ Stoppen', pushTitle:'Video-URL an CarPlay / Mivu senden', urlPlaceholder:'HTTP/HTTPS- oder HLS-m3u8-URL eingeben', push:'🚀 Auf Mivu abspielen', uploadTitle:'Über WLAN auf Mivu laden', upload:'⬆️ In die Mediathek laden', uploadHint:'Videos werden in der Mivu-Mediathek dieses Geräts gespeichert.', playing:'Video wird abgespielt', noMedia:'Keine Medien', enterURL:'Video-URL eingeben', chooseFile:'Videodatei auswählen', uploading:'Wird hochgeladen', uploaded:'Upload abgeschlossen. In der Mivu-Mediathek gespeichert.', failed:'Upload fehlgeschlagen. Unterstütztes Video unter 10 GB verwenden.', offline:'Verbindung unterbrochen. Upload unvollständig.', preparing:'Upload wird vorbereitet…' },
              es: { heading:'Control remoto y envío de Mivu', nowPlaying:'Reproduciendo', loading:'Cargando…', toggle:'⏯ Reproducir/Pausar', stop:'⏹ Detener', pushTitle:'Enviar URL de video a CarPlay / Mivu', urlPlaceholder:'Introduce una URL HTTP/HTTPS o HLS m3u8', push:'🚀 Reproducir en Mivu', uploadTitle:'Subir a Mivu por Wi-Fi', upload:'⬆️ Subir a la biblioteca', uploadHint:'Los videos se guardan en la biblioteca Mivu de este dispositivo.', playing:'Reproduciendo video', noMedia:'Sin contenido', enterURL:'Introduce una URL de video', chooseFile:'Selecciona un archivo de video', uploading:'Subiendo', uploaded:'Carga completada. Guardado en la biblioteca Mivu.', failed:'Error al subir. Usa un video compatible de menos de 10 GB.', offline:'Conexión interrumpida. La carga no se completó.', preparing:'Preparando la carga…' },
              'pt-BR': { heading:'Controle remoto e transmissão Mivu', nowPlaying:'Reproduzindo agora', loading:'Carregando…', toggle:'⏯ Reproduzir/Pausar', stop:'⏹ Parar', pushTitle:'Enviar URL de vídeo para CarPlay / Mivu', urlPlaceholder:'Digite uma URL HTTP/HTTPS ou HLS m3u8', push:'🚀 Reproduzir no Mivu', uploadTitle:'Enviar para o Mivu via Wi-Fi', upload:'⬆️ Enviar para a biblioteca', uploadHint:'Os vídeos são salvos na biblioteca Mivu deste dispositivo.', playing:'Reproduzindo vídeo', noMedia:'Sem mídia', enterURL:'Digite uma URL de vídeo', chooseFile:'Selecione um arquivo de vídeo', uploading:'Enviando', uploaded:'Envio concluído. Salvo na biblioteca Mivu.', failed:'Falha no envio. Use um vídeo compatível com menos de 10 GB.', offline:'Conexão interrompida. Envio incompleto.', preparing:'Preparando envio…' }
            };
            const accessMessages = {
              en: { accessTitle:'Access Code', accessPlaceholder:'Enter the 6-digit code shown in Mivu', unlock:'Unlock Remote', accessHint:'Enter the code from Mivu to control or upload.', accessDenied:'Incorrect access code.' },
              'zh-Hans': { accessTitle:'访问码', accessPlaceholder:'输入 Mivu 中显示的 6 位访问码', unlock:'解锁遥控器', accessHint:'输入 Mivu 中的访问码后即可控制或上传。', accessDenied:'访问码错误。' },
              'zh-Hant': { accessTitle:'存取碼', accessPlaceholder:'輸入 Mivu 中顯示的 6 位存取碼', unlock:'解鎖遙控器', accessHint:'輸入 Mivu 中的存取碼後即可控制或上傳。', accessDenied:'存取碼錯誤。' },
              fr: { accessTitle:'Code d’accès', accessPlaceholder:'Saisissez le code à 6 chiffres affiché dans Mivu', unlock:'Déverrouiller la télécommande', accessHint:'Saisissez le code de Mivu pour contrôler ou importer.', accessDenied:'Code d’accès incorrect.' },
              de: { accessTitle:'Zugangscode', accessPlaceholder:'Gib den in Mivu angezeigten 6-stelligen Code ein', unlock:'Fernbedienung entsperren', accessHint:'Gib den Code aus Mivu ein, um zu steuern oder hochzuladen.', accessDenied:'Falscher Zugangscode.' },
              es: { accessTitle:'Código de acceso', accessPlaceholder:'Introduce el código de 6 dígitos mostrado en Mivu', unlock:'Desbloquear control remoto', accessHint:'Introduce el código de Mivu para controlar o subir archivos.', accessDenied:'Código de acceso incorrecto.' },
              'pt-BR': { accessTitle:'Código de acesso', accessPlaceholder:'Digite o código de 6 dígitos exibido no Mivu', unlock:'Desbloquear controle remoto', accessHint:'Digite o código do Mivu para controlar ou enviar arquivos.', accessDenied:'Código de acesso incorreto.' }
            };
            const tr = (key) => (messages[language] || messages.en)[key] || (accessMessages[language] || accessMessages.en)[key];
            document.documentElement.lang = language;
            document.querySelectorAll('[data-i18n]').forEach(el => el.textContent = tr(el.dataset.i18n));
            document.querySelectorAll('[data-i18n-placeholder]').forEach(el => el.placeholder = tr(el.dataset.i18nPlaceholder));
            document.title = 'Mivu ' + tr('heading');
            const accessCodeKey = 'mivu-web-access-code';
            const accessCodeInput = document.getElementById('accessCodeInput');
            const accessCodeStatus = document.getElementById('accessCodeStatus');
            const accessCodeFromFragment = new URLSearchParams(window.location.hash.slice(1)).get('access-code');
            if (/^\\d{6}$/.test(accessCodeFromFragment || '')) {
              sessionStorage.setItem(accessCodeKey, accessCodeFromFragment);
              history.replaceState(null, '', window.location.pathname);
            }
            accessCodeInput.value = sessionStorage.getItem(accessCodeKey) || '';
            const currentAccessCode = () => accessCodeInput.value.trim();
            async function authenticatedFetch(url, options = {}) {
              const headers = new Headers(options.headers || {});
              const code = currentAccessCode();
              if (code) headers.set('X-Mivu-Access-Code', code);
              return fetch(url, { ...options, headers });
            }
            async function unlockWebRemote() {
              const code = currentAccessCode();
              if (!/^\\d{6}$/.test(code)) {
                accessCodeStatus.textContent = tr('accessHint');
                return;
              }
              sessionStorage.setItem(accessCodeKey, code);
              try {
                const response = await authenticatedFetch('/api/status');
                if (response.status === 401) {
                  sessionStorage.removeItem(accessCodeKey);
                  accessCodeStatus.textContent = tr('accessDenied');
                  return;
                }
                accessCodeStatus.textContent = '';
                fetchStatus();
              } catch (_) {
                accessCodeStatus.textContent = tr('offline');
              }
            }
            async function fetchStatus() {
              try {
                const res = await authenticatedFetch('/api/status');
                if (!res.ok) return;
                const data = await res.json();
                document.getElementById('mediaTitle').innerText = data.title || (data.status === 'PLAYING' ? tr('playing') : tr('noMedia'));
                const formatTime = (s) => {
                  if (!s || isNaN(s)) return '00:00:00';
                  const sec = Math.floor(s);
                  return String(Math.floor(sec/3600)).padStart(2,'0') + ':' +
                         String(Math.floor((sec%3600)/60)).padStart(2,'0') + ':' +
                         String(sec%60).padStart(2,'0');
                };
                document.getElementById('mediaTime').innerText = formatTime(data.currentTime) + ' / ' + formatTime(data.duration) + ' (' + data.status + ')';
              } catch(e) {}
            }
            setInterval(() => { if (currentAccessCode()) fetchStatus(); }, 1500);
            if (currentAccessCode()) unlockWebRemote();

            async function sendControl(action, value) {
              await authenticatedFetch('/api/control', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action, value })
              });
              fetchStatus();
            }

            async function pushVideo() {
              const url = document.getElementById('videoUrlInput').value.trim();
              if (!url) return alert(tr('enterURL'));
              await authenticatedFetch('/api/play', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ url })
              });
              document.getElementById('videoUrlInput').value = '';
              fetchStatus();
            }

            function uploadVideo() {
              const input = document.getElementById('videoFileInput');
              const file = input.files[0];
              if (!file) return alert(tr('chooseFile'));

              const button = document.getElementById('uploadButton');
              const progress = document.getElementById('uploadProgress');
              const status = document.getElementById('uploadStatus');
              const accessCode = currentAccessCode();
              if (!accessCode) {
                status.textContent = tr('accessHint');
                return;
              }
              const request = new XMLHttpRequest();
              request.open('POST', '/api/upload?filename=' + encodeURIComponent(file.name));
              request.setRequestHeader('Content-Type', file.type || 'application/octet-stream');
              request.setRequestHeader('X-Mivu-Access-Code', accessCode);
              request.upload.onprogress = (event) => {
                if (!event.lengthComputable) return;
                const percent = Math.round(event.loaded / event.total * 100);
                progress.value = percent;
                status.textContent = tr('uploading') + ' ' + percent + '%';
              };
              request.onload = () => {
                button.disabled = false;
                progress.hidden = true;
                if (request.status === 200) {
                  status.textContent = tr('uploaded');
                  input.value = '';
                } else {
                  status.textContent = tr('failed');
                }
              };
              request.onerror = () => {
                button.disabled = false;
                progress.hidden = true;
                status.textContent = tr('offline');
              };
              button.disabled = true;
              progress.value = 0;
              progress.hidden = false;
              status.textContent = tr('preparing');
              request.send(file);
            }
          </script>
        </body>
        </html>
        """
    }
}

// MARK: - Wi-Fi Uploaded Video Storage

public enum UploadedVideoStore {
    private static let folderName = "Mivu Uploads"
    private static let supportedExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "webm", "ts", "m2ts", "mpg", "mpeg", "3gp"
    ]

    public static func isSupportedVideo(filename: String) -> Bool {
        supportedExtensions.contains(URL(fileURLWithPath: filename).pathExtension.lowercased())
    }

    public static func videos() -> [URL] {
        guard let directory = try? directoryURL(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }

        return urls
            .filter { isSupportedVideo(filename: $0.lastPathComponent) }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
    }

    public static func mediaItem(for url: URL) -> MediaItem {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        return MediaItem(
            title: url.deletingPathExtension().lastPathComponent,
            url: url,
            sourceType: .directUrl,
            originator: "Wi-Fi Upload",
            fileName: url.lastPathComponent,
            fileSize: size
        )
    }

    public static func delete(_ url: URL) throws {
        let directory = try directoryURL().standardizedFileURL
        guard url.deletingLastPathComponent().standardizedFileURL == directory else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.removeItem(at: url)
    }

    fileprivate static func uniqueDestination(for providedName: String) throws -> URL {
        let directory = try directoryURL()
        let safeName = URL(fileURLWithPath: providedName).lastPathComponent
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
        let baseName = URL(fileURLWithPath: safeName).deletingPathExtension().lastPathComponent
        let extensionName = URL(fileURLWithPath: safeName).pathExtension.lowercased()
        let normalizedBase = baseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "视频" : baseName

        var candidate = directory.appendingPathComponent(normalizedBase).appendingPathExtension(extensionName)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(normalizedBase) (\(index))").appendingPathExtension(extensionName)
            index += 1
        }
        return candidate
    }

    private static func directoryURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

public extension Notification.Name {
    static let mivuUploadedVideosDidChange = Notification.Name("mivu.uploaded-videos-did-change")
}

// MARK: - Network IP Helper

public enum NetworkHelper {
    public struct IPv4Interface: Sendable {
        public let name: String
        public let address: String
    }

    public static func activeIPv4Interfaces() -> [IPv4Interface] {
        var results: [IPv4Interface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard let socketAddress = interface.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET),
                  (interface.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }

            results.append(IPv4Interface(
                name: String(cString: interface.ifa_name),
                address: String(cString: hostname)
            ))
        }
        return results
    }

    public static func getWiFiAddress() -> String? {
        let interfaces = activeIPv4Interfaces()
        return interfaces.first(where: { $0.name == "en0" })?.address
            ?? interfaces.first(where: { $0.name.hasPrefix("pdp_ip") })?.address
            ?? interfaces.first(where: { $0.name == "lo0" })?.address
    }
}
