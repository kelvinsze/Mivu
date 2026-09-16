import Foundation
import SMBClient

/// SMB2 media browser and player source. SMB1 is intentionally unsupported.
public final class SMBMediaClient: MediaServerProtocol, @unchecked Sendable {
    public let serverId: UUID
    public let serverName: String
    public let serverBaseURL: URL
    private let configuration: SMBPlaybackConfiguration
    private var password: String?

    public var isAuthenticated: Bool { password != nil }

    public init(id: UUID = UUID(), serverName: String, serverBaseURL: URL, username: String, password: String? = nil) throws {
        guard let configuration = SMBPlaybackConfiguration(url: serverBaseURL, username: username, password: password) else {
            throw MediaServerError.invalidURL
        }
        self.serverId = id
        self.serverName = serverName
        self.serverBaseURL = serverBaseURL
        self.configuration = configuration
        self.password = password
        if password != nil { SMBPlaybackRegistry.shared.register(configuration, for: id) }
    }

    public func authenticate(username: String, password: String) async throws -> String {
        let configuration = SMBPlaybackConfiguration(url: serverBaseURL, username: username, password: password)
        guard let configuration else { throw MediaServerError.invalidURL }
        try await withClient(configuration: configuration) { client in
            if !configuration.share.isEmpty {
                _ = try await client.listDirectory(path: configuration.rootPath)
            } else {
                _ = try? await client.listShares()
            }
        }
        self.password = password
        SMBPlaybackRegistry.shared.register(configuration, for: serverId)
        return password
    }

    public func fetchLibraries() async throws -> [MediaLibrary] {
        guard let configuration = authenticatedConfiguration else { throw MediaServerError.notAuthenticated }
        if !configuration.share.isEmpty {
            return [MediaLibrary(id: configuration.share, name: configuration.share, collectionType: "videos")]
        }

        return try await withClient(configuration: configuration) { client in
            do {
                let shares = try await client.listShares()
                let visibleShares = shares.filter { share in
                    let name = share.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, !name.hasSuffix("$") else { return false }
                    guard !share.type.contains(.special),
                          !share.type.contains(.ipc),
                          !share.type.contains(.printQueue),
                          !share.type.contains(.device) else { return false }
                    return true
                }
                if visibleShares.isEmpty {
                    return [MediaLibrary(id: "default", name: self.serverName, collectionType: "videos")]
                }
                return visibleShares.map { share in
                    let comment = share.comment.trimmingCharacters(in: .whitespacesAndNewlines)
                    let displayName = comment.isEmpty ? share.name : "\(share.name) (\(comment))"
                    return MediaLibrary(id: share.name, name: displayName, collectionType: "videos")
                }
            } catch {
                return [MediaLibrary(id: "default", name: self.serverName, collectionType: "videos")]
            }
        }
    }

    public func fetchItems(libraryId: String, startIndex: Int, limit: Int) async throws -> [MediaItem] {
        guard let configuration = authenticatedConfiguration else { throw MediaServerError.notAuthenticated }
        let shareName: String
        let rootDir: String
        if !configuration.share.isEmpty {
            shareName = configuration.share
            rootDir = configuration.rootPath
        } else {
            shareName = (libraryId == "default") ? "" : libraryId
            rootDir = ""
        }
        guard !shareName.isEmpty else { return [] }
        let files = try await scanVideoFiles(configuration: configuration, share: shareName, rootDirectory: rootDir, maximumCount: max(startIndex + limit, 100))
        return Array(files.dropFirst(startIndex).prefix(limit))
    }

    public func fetchPlaybackInfo(itemId: String) async throws -> MediaPlaybackInfo {
        guard let configuration = authenticatedConfiguration else { throw MediaServerError.notAuthenticated }
        guard let url = SMBPlaybackRegistry.shared.url(for: serverId, remotePath: itemId, fileName: URL(fileURLWithPath: itemId).lastPathComponent) else {
            throw MediaServerError.invalidURL
        }
        SMBPlaybackRegistry.shared.register(configuration, for: serverId)
        return MediaPlaybackInfo(itemId: itemId, url: url, method: .directPlay)
    }

    public func fetchPlaybackStreamURL(itemId: String) async throws -> URL {
        try await fetchPlaybackInfo(itemId: itemId).url
    }

    public func search(query: String, limit: Int) async throws -> [MediaItem] {
        guard let configuration = authenticatedConfiguration else { throw MediaServerError.notAuthenticated }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        if !configuration.share.isEmpty {
            return try await scanVideoFiles(configuration: configuration, share: configuration.share, rootDirectory: configuration.rootPath, maximumCount: 400)
                .filter { $0.title.localizedCaseInsensitiveContains(needle) }
                .prefix(limit)
                .map { $0 }
        } else {
            let libraries = try await fetchLibraries()
            var allResults: [MediaItem] = []
            for lib in libraries where lib.id != "default" {
                let items = try await scanVideoFiles(configuration: configuration, share: lib.id, rootDirectory: "", maximumCount: 200)
                allResults.append(contentsOf: items.filter { $0.title.localizedCaseInsensitiveContains(needle) })
                if allResults.count >= limit { break }
            }
            return Array(allResults.prefix(limit))
        }
    }

    public func fetchContinueWatching(limit: Int) async throws -> [MediaItem] { [] }

    public func reportPlaybackProgress(itemId: String, position: TimeInterval, isPaused: Bool, isStopped: Bool, playSessionId: String?, mediaSourceId: String?) async throws {
        // SMB has no standard playback-history protocol.
    }

    private var authenticatedConfiguration: SMBPlaybackConfiguration? {
        guard let password else { return nil }
        return configuration.with(password: password)
    }

    private func scanVideoFiles(configuration: SMBPlaybackConfiguration, share: String, rootDirectory: String, maximumCount: Int) async throws -> [MediaItem] {
        try await withClient(configuration: configuration, share: share) { client in
            var pending = [rootDirectory]
            var visited = Set<String>()
            var results: [MediaItem] = []
            while let directory = pending.popLast(), results.count < maximumCount, visited.count < 256 {
                guard visited.insert(directory).inserted else { continue }
                for entry in try await client.listDirectory(path: directory) where entry.name != "." && entry.name != ".." {
                    let path = Self.join(directory, entry.name)
                    if entry.isDirectory {
                        pending.append(path)
                    } else if Self.playableExtensions.contains(URL(fileURLWithPath: entry.name).pathExtension.lowercased()) {
                        let remotePath = configuration.share.isEmpty ? "\(share)/\(path)" : path
                        guard let url = SMBPlaybackRegistry.shared.url(for: serverId, remotePath: remotePath, fileName: entry.name) else { continue }
                        results.append(MediaItem(
                            title: entry.name,
                            url: url,
                            sourceType: .personalMedia,
                            originator: serverName,
                            serverID: serverId,
                            serverItemID: remotePath,
                            containerHint: URL(fileURLWithPath: entry.name).pathExtension.lowercased()
                        ))
                        if results.count == maximumCount { break }
                    }
                }
            }
            return results.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    private func withClient<T>(configuration: SMBPlaybackConfiguration, share: String? = nil, operation: (SMBClient) async throws -> T) async throws -> T {
        let client = SMBClient(host: configuration.host, port: configuration.port)
        do {
            let user = configuration.username.isEmpty ? nil : configuration.username
            let pass = (configuration.password?.isEmpty == true) ? nil : configuration.password
            try await client.login(username: user, password: pass)
            let targetShare = share ?? configuration.share
            var isConnected = false
            if !targetShare.isEmpty {
                try await client.connectShare(targetShare)
                isConnected = true
            }
            let result = try await operation(client)
            if isConnected {
                _ = try? await client.disconnectShare()
            }
            _ = try? await client.logoff()
            return result
        } catch {
            if !(share ?? configuration.share).isEmpty {
                _ = try? await client.disconnectShare()
            }
            _ = try? await client.logoff()
            throw error
        }
    }

    private static func join(_ directory: String, _ name: String) -> String {
        directory.isEmpty ? name : "\(directory)/\(name)"
    }

    private static let playableExtensions: Set<String> = ["m3u8", "mp4", "m4v", "mov", "mkv", "webm", "avi", "ts", "m2ts", "mpg", "mpeg", "mpd"]
}

public struct SMBPlaybackConfiguration: Sendable {
    public let host: String
    public let port: Int
    public let share: String
    public let rootPath: String
    public let username: String
    public let password: String?

    init?(url: URL, username: String, password: String?) {
        guard url.scheme?.lowercased() == "smb", let host = url.host, !host.isEmpty else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        self.host = host
        self.port = url.port ?? 445
        self.share = components.first?.removingPercentEncoding ?? ""
        self.rootPath = components.dropFirst().compactMap { $0.removingPercentEncoding }.joined(separator: "/")
        self.username = username
        self.password = password
    }

    func with(password: String) -> SMBPlaybackConfiguration {
        SMBPlaybackConfiguration(host: host, port: port, share: share, rootPath: rootPath, username: username, password: password)
    }

    private init(host: String, port: Int, share: String, rootPath: String, username: String, password: String?) {
        self.host = host; self.port = port; self.share = share; self.rootPath = rootPath; self.username = username; self.password = password
    }
}

/// Maps opaque AVAsset URLs to their SMB credentials without putting them in
/// URLs, history, diagnostics, or Now Playing metadata.
public final class SMBPlaybackRegistry: @unchecked Sendable {
    public static let shared = SMBPlaybackRegistry()
    private let lock = NSLock()
    private var configurations: [UUID: SMBPlaybackConfiguration] = [:]

    private init() {}

    public func register(_ configuration: SMBPlaybackConfiguration, for serverID: UUID) {
        lock.lock(); defer { lock.unlock() }
        configurations[serverID] = configuration
    }

    public func configuration(for url: URL) -> SMBPlaybackConfiguration? {
        guard url.scheme == "mivu-smb", let host = url.host, let id = UUID(uuidString: host) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return configurations[id]
    }

    public func remotePath(for url: URL) -> String? {
        guard url.scheme == "mivu-smb" else { return nil }
        return url.path.removingPercentEncoding?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public func url(for serverID: UUID, remotePath: String, fileName: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mivu-smb"
        components.host = serverID.uuidString
        let cleanPath = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/\(cleanPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cleanPath)"
        return components.url
    }
}
