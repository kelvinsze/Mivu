import Foundation
import Network
import UIKit
import OSLog

private let logger = Logger(subsystem: "com.kelvinsze.mivu", category: "HTTPServer")

/// Embedded lightweight HTTP & REST / Web Remote server using Network.framework.
public final class HTTPServer: @unchecked Sendable {
    public static let shared = HTTPServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.kelvinsze.mivu.httpserver", qos: .userInitiated)
    private var isRunning = false
    public private(set) var port: UInt16 = 7890

    public var localIPAddress: String {
        return NetworkHelper.getWiFiAddress() ?? "127.0.0.1"
    }

    private init() {}

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

            // Check if headers are completely received
            if let headerEndRange = currentData.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = currentData.subdata(in: 0..<headerEndRange.lowerBound)
                let bodyData = currentData.subdata(in: headerEndRange.upperBound..<currentData.count)

                guard let headerString = String(data: headerData, encoding: .utf8) else {
                    self.sendResponse(connection: connection, statusCode: 400, contentType: "text/plain", body: "Bad Request")
                    return
                }

                let headers = self.parseHeaders(headerString)
                let contentLength = Int(headers["content-length"] ?? "0") ?? 0

                if bodyData.count >= contentLength {
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
                let sectionsCount = cpDelegate?.rootTemplate?.sections.count ?? 0

                let json: [String: Any] = [
                    "connectedScenes": scenes,
                    "carPlayDelegateShared": cpDelegate != nil,
                    "isConnected": isConn,
                    "hasInterfaceController": hasInterface,
                    "hasRootTemplate": hasRoot,
                    "rootTemplateSectionsCount": sectionsCount,
                    "isVideoPlaybackAvailable": videoAvail,
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
               let url = URL(string: urlStr) {
                let title = (json["title"] as? String) ?? url.lastPathComponent
                let item = MediaItem(
                    title: title.isEmpty ? "Web Stream" : title,
                    url: url,
                    sourceType: .directUrl,
                    originator: "Web Remote"
                )
                Task { @MainActor in
                    PlayerService.shared.loadAndPlay(item: item)
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
        let statusText = statusCode == 200 ? "OK" : (statusCode == 404 ? "Not Found" : "Internal Server Error")
        let bodyData = Data(body.utf8)
        let responseHeader = """
        HTTP/1.1 \(statusCode) \(statusText)\r
        Server: iOS/17 UPnP/1.0 Mivu/0.1\r
        Content-Type: \(contentType)\r
        Content-Length: \(bodyData.count)\r
        Access-Control-Allow-Origin: *\r
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
        <html lang="zh-CN">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
          <title>Mivu 网页遥控器</title>
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
            input[type="text"] {
              width: 100%;
              padding: 0.75rem 1rem;
              background: rgba(0,0,0,0.3);
              border: 1px solid rgba(255,255,255,0.1);
              border-radius: 0.5rem;
              color: #fff;
              font-size: 0.9rem;
              margin-bottom: 0.75rem;
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
              <h1>Mivu 遥控与投送</h1>
              <div class="badge">\(friendlyName)</div>
            </header>

            <div class="card">
              <div class="card-title">当前播放</div>
              <div class="status-text" id="mediaTitle">加载中...</div>
              <div class="time-bar" id="mediaTime">00:00:00 / 00:00:00</div>
              <div class="controls-row">
                <button class="btn-ctrl" onclick="sendControl('toggle')">⏯ 播放/暂停</button>
                <button class="btn-ctrl" onclick="sendControl('stop')">⏹ 停止</button>
              </div>
            </div>

            <div class="card">
              <div class="card-title">推送视频 URL 到 CarPlay / Mivu</div>
              <input type="text" id="videoUrlInput" placeholder="输入 HTTP/HTTPS 或 HLS m3u8 链接">
              <button class="btn-primary" onclick="pushVideo()">🚀 立即投送播放</button>
            </div>
          </div>

          <script>
            async function fetchStatus() {
              try {
                const res = await fetch('/api/status');
                const data = await res.json();
                document.getElementById('mediaTitle').innerText = data.title || (data.status === 'PLAYING' ? '正在播放视频' : '无媒体');
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
            setInterval(fetchStatus, 1500);
            fetchStatus();

            async function sendControl(action, value) {
              await fetch('/api/control', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action, value })
              });
              fetchStatus();
            }

            async function pushVideo() {
              const url = document.getElementById('videoUrlInput').value.trim();
              if (!url) return alert('请输入视频链接');
              await fetch('/api/play', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ url })
              });
              document.getElementById('videoUrlInput').value = '';
              fetchStatus();
            }
          </script>
        </body>
        </html>
        """
    }
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
