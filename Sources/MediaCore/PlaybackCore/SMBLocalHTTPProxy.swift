import Foundation
import Network
import SMBClient
import UniformTypeIdentifiers

/// A loopback-only, capability-URL HTTP adapter for SMB byte ranges.
///
/// libmpv accepts regular HTTP range streams but cannot consume AVFoundation's
/// resource-loader callbacks. The URL contains an unguessable, short-lived
/// identifier only: SMB host, path, username, and password never leave the
/// in-memory playback registry.
final class SMBLocalHTTPProxy: @unchecked Sendable {
    static let shared = SMBLocalHTTPProxy()

    private struct Resource {
        let configuration: SMBPlaybackConfiguration
        let remotePath: String
        let reader: SMBRangeReader

        func matches(configuration: SMBPlaybackConfiguration, remotePath: String) -> Bool {
            self.remotePath == remotePath
                && self.configuration.host == configuration.host
                && self.configuration.port == configuration.port
                && self.configuration.share == configuration.share
                && self.configuration.rootPath == configuration.rootPath
                && self.configuration.username == configuration.username
                && self.configuration.password == configuration.password
        }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.kold.mivu.smb-loopback", qos: .userInitiated)
    private var listener: NWListener?
    private var listeningPort: UInt16?
    private var resources: [String: Resource] = [:]
    private var resourceTokens: [String: String] = [:]

    private init() {}

    var isOperational: Bool {
        lock.lock(); defer { lock.unlock() }
        return listeningPort != nil
    }

    func start() {
        lock.lock()
        guard listener == nil else {
            lock.unlock()
            return
        }
        lock.unlock()

        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.lock.lock()
                    self.listeningPort = listener?.port?.rawValue
                    self.lock.unlock()
                case .failed, .cancelled:
                    self.lock.lock()
                    self.listeningPort = nil
                    self.listener = nil
                    self.lock.unlock()
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            lock.lock()
            self.listener = listener
            lock.unlock()
            listener.start(queue: queue)
        } catch {
            // The main player will keep using AVPlayer when a loopback listener
            // cannot be created; errors are surfaced by the normal playback UI.
        }
    }

    func stop() {
        lock.lock()
        let listener = self.listener
        self.listener = nil
        listeningPort = nil
        resources.removeAll()
        resourceTokens.removeAll()
        lock.unlock()
        listener?.cancel()
    }

    /// Returns a local HTTP stream URL for an opaque `mivu-smb` item.
    func url(for sourceURL: URL) -> URL? {
        guard let configuration = SMBPlaybackRegistry.shared.configuration(for: sourceURL),
              let remotePath = SMBPlaybackRegistry.shared.remotePath(for: sourceURL),
              !remotePath.isEmpty,
              configuration.password != nil else { return nil }

        lock.lock()
        defer { lock.unlock() }
        guard let port = listeningPort else { return nil }
        let key = sourceURL.absoluteString
        let token = resourceTokens[key] ?? UUID().uuidString.lowercased()
        if resources[token]?.matches(configuration: configuration, remotePath: remotePath) != true {
            resources[token] = Resource(
                configuration: configuration,
                remotePath: remotePath,
                reader: SMBRangeReader(configuration: configuration, remotePath: remotePath)
            )
        }
        resourceTokens[key] = token
        let extensionName = URL(fileURLWithPath: remotePath).pathExtension
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        return URL(string: "http://127.0.0.1:\(port)/smb/\(token)/stream\(extensionName.isEmpty ? "" : ".\(extensionName)")")
    }

    private func resource(for token: String) -> Resource? {
        lock.lock(); defer { lock.unlock() }
        return resources[token]
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, _, error in
            guard let self, error == nil, let content,
                  let request = String(data: content, encoding: .utf8) else {
                connection.cancel()
                return
            }
            Task { await self.respond(to: request, connection: connection) }
        }
    }

    private func respond(to request: String, connection: NWConnection) async {
        let lines = request.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else {
            await send(status: 400, headers: [:], connection: connection)
            return
        }
        let method = String(parts[0]).uppercased()
        guard method == "GET" || method == "HEAD",
              let components = URLComponents(string: "http://localhost\(parts[1])") else {
            await send(status: 405, headers: [:], connection: connection)
            return
        }
        let path = components.path.split(separator: "/")
        guard path.count == 3, path[0] == "smb", let resource = resource(for: String(path[1])) else {
            await send(status: 404, headers: [:], connection: connection)
            return
        }

        let headers = Dictionary(uniqueKeysWithValues: lines.dropFirst().compactMap { line -> (String, String)? in
            let fields = line.split(separator: ":", maxSplits: 1)
            guard fields.count == 2 else { return nil }
            return (fields[0].trimmingCharacters(in: .whitespaces).lowercased(), fields[1].trimmingCharacters(in: .whitespaces))
        })
        let reader = resource.reader
        do {
            let metadata = try await reader.metadata()
            guard let responseRange = Self.range(headers["range"], fileLength: metadata.length) else {
                await send(status: 416, headers: ["Content-Range": "bytes */\(metadata.length)"], connection: connection)
                return
            }
            let isPartial = headers["range"] != nil
            let contentType = UTType(filenameExtension: URL(fileURLWithPath: resource.remotePath).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            var responseHeaders = [
                "Accept-Ranges": "bytes",
                "Cache-Control": "no-store",
                "Content-Type": contentType,
                "Content-Length": "\(responseRange.length)"
            ]
            if isPartial {
                responseHeaders["Content-Range"] = "bytes \(responseRange.offset)-\(responseRange.offset + UInt64(responseRange.length) - 1)/\(metadata.length)"
            }
            try await send(status: isPartial ? 206 : 200, headers: responseHeaders, connection: connection, close: method == "HEAD")
            guard method == "GET" else { return }

            var offset = responseRange.offset
            var remaining = responseRange.length
            while remaining > 0 {
                let count = min(remaining, 512 * 1024)
                let data = try await reader.read(offset: offset, length: UInt32(count))
                guard !data.isEmpty else { break }
                try await send(data, connection: connection)
                offset += UInt64(data.count)
                remaining -= data.count
            }
            connection.cancel()
        } catch {
            connection.cancel()
        }
    }

    private static func range(_ header: String?, fileLength: UInt64) -> (offset: UInt64, length: Int)? {
        guard fileLength > 0 else { return nil }
        guard let header else {
            return fileLength <= UInt64(Int.max) ? (0, Int(fileLength)) : nil
        }
        guard header.lowercased().hasPrefix("bytes="),
              let value = header.dropFirst(6).split(separator: ",").first else { return nil }
        let bounds = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }
        if bounds[0].isEmpty, let suffix = UInt64(bounds[1]), suffix > 0 {
            let length = min(suffix, fileLength)
            return (fileLength - length, Int(length))
        }
        guard let start = UInt64(bounds[0]), start < fileLength else { return nil }
        let end = UInt64(bounds[1]) ?? (fileLength - 1)
        let length = min(end, fileLength - 1) - start + 1
        return length <= UInt64(Int.max) ? (start, Int(length)) : nil
    }

    private func send(status: Int, headers: [String: String], connection: NWConnection) async {
        var response = "HTTP/1.1 \(status) \(Self.statusText(status))\r\n"
        for (name, value) in headers { response += "\(name): \(value)\r\n" }
        response += "Connection: close\r\n\r\n"
        _ = try? await send(Data(response.utf8), connection: connection)
        connection.cancel()
    }

    private func send(status: Int, headers: [String: String], connection: NWConnection, close: Bool) async throws {
        var response = "HTTP/1.1 \(status) \(Self.statusText(status))\r\n"
        for (name, value) in headers { response += "\(name): \(value)\r\n" }
        response += "Connection: close\r\n\r\n"
        try await send(Data(response.utf8), connection: connection)
        if close { connection.cancel() }
    }

    private func send(_ data: Data, connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private static func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 416: return "Range Not Satisfiable"
        default: return "Internal Server Error"
        }
    }
}
