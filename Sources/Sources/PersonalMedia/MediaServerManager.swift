import Foundation
import OSLog
import Security

private let logger = Logger(subsystem: "com.kold.mivu", category: "MediaServerManager")

public enum MediaServerType: String, Codable, Sendable, CaseIterable {
    case emby
    case jellyfin
    case webDAV = "webdav"
    case smb
    /// fnOS is connected through its documented WebDAV endpoint. Its private
    /// media-library API is deliberately not assumed to be stable.
    case fnos
}

public struct MediaServerCredential: Codable, Sendable, Equatable {
    public let username: String
    public let token: String?
    public let userId: String?

    public init(username: String, token: String?, userId: String?) {
        self.username = username
        self.token = token
        self.userId = userId
    }
}

public enum MediaServerCredentialMigration {
    public static func shouldMigrate(hasUsername: Bool, hasUserId: Bool, hasToken: Bool) -> Bool {
        hasUsername || hasUserId || hasToken
    }
}

public enum KeychainTokenStore {
    private static let service = "com.kold.mivu.media-server-token"

    @discardableResult
    public static func save(_ credential: MediaServerCredential, for serverID: UUID) -> Bool {
        guard let data = try? JSONEncoder().encode(credential) else { return false }
        return saveData(data, for: serverID)
    }

    private static func saveData(_ data: Data, for serverID: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID.uuidString
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            return SecItemUpdate(query as CFDictionary, [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ] as CFDictionary) == errSecSuccess
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public static func readCredential(for serverID: UUID) -> MediaServerCredential? {
        guard let data = readData(for: serverID) else { return nil }
        if let credential = try? JSONDecoder().decode(MediaServerCredential.self, from: data) {
            return credential
        }
        guard let token = String(data: data, encoding: .utf8) else { return nil }
        return MediaServerCredential(username: "", token: token, userId: nil)
    }

    private static func readData(for serverID: UUID) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return data
    }

    public static func delete(for serverID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}

public struct SavedServerInfo: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var url: URL
    public var serverType: MediaServerType
    public var username: String
    public var userId: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, url, serverType, username, userId, token
    }

    public init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        serverType: MediaServerType,
        username: String,
        token: String? = nil,
        userId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.serverType = serverType
        self.username = username
        self.userId = userId
        KeychainTokenStore.save(MediaServerCredential(username: username, token: token, userId: userId), for: id)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(UUID.self, forKey: .id)
        self.id = id
        self.name = try values.decode(String.self, forKey: .name)
        self.url = try values.decode(URL.self, forKey: .url)
        let rawType = try values.decode(String.self, forKey: .serverType).lowercased()
        guard let serverType = MediaServerType(rawValue: rawType) else {
            throw DecodingError.dataCorruptedError(forKey: .serverType, in: values, debugDescription: "Unsupported media server type: \(rawType)")
        }
        self.serverType = serverType
        let hasUsername = values.contains(.username)
        let hasUserId = values.contains(.userId)
        let hasToken = values.contains(.token)
        if MediaServerCredentialMigration.shouldMigrate(hasUsername: hasUsername, hasUserId: hasUserId, hasToken: hasToken) {
            self.username = try values.decodeIfPresent(String.self, forKey: .username) ?? ""
            self.userId = try values.decodeIfPresent(String.self, forKey: .userId)
            let legacyToken = try values.decodeIfPresent(String.self, forKey: .token)
            KeychainTokenStore.save(MediaServerCredential(username: username, token: legacyToken, userId: userId), for: id)
        } else {
            let existing = KeychainTokenStore.readCredential(for: id)
            self.username = existing?.username ?? ""
            self.userId = existing?.userId
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(url, forKey: .url)
        try values.encode(serverType, forKey: .serverType)
        // Credentials are intentionally excluded from UserDefaults.
    }
}

/// Manages personal media server instances (Emby / Jellyfin).
@MainActor
public final class MediaServerManager: ObservableObject {
    public static let shared = MediaServerManager()

    private let storageKey = "mivu_saved_media_servers_v1"
    @Published public private(set) var savedServers: [SavedServerInfo] = []
    @Published public private(set) var activeClients: [UUID: MediaServerProtocol] = [:]

    public init() {
        loadServers()
    }

    public func addServer(name: String, url: URL, type: MediaServerType, username: String, token: String?, userId: String?) {
        let newInfo = SavedServerInfo(name: name, url: url, serverType: type, username: username, token: token, userId: userId)
        savedServers.append(newInfo)
        saveServers()
        instantiateClient(for: newInfo)
    }

    public func removeServer(id: UUID) {
        savedServers.removeAll { $0.id == id }
        activeClients.removeValue(forKey: id)
        KeychainTokenStore.delete(for: id)
        saveServers()
    }

    public func getClient(for id: UUID) -> MediaServerProtocol? {
        return activeClients[id]
    }

    private func loadServers() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        do {
            savedServers = try JSONDecoder().decode([SavedServerInfo].self, from: data)
            for server in savedServers {
                instantiateClient(for: server)
            }
            // Re-encode immediately so legacy token fields are removed from UserDefaults.
            saveServers()
        } catch {
            logger.error("Failed to load saved media servers: \(error.localizedDescription)")
        }
    }

    private func saveServers() {
        do {
            let data = try JSONEncoder().encode(savedServers)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            logger.error("Failed to save media servers: \(error.localizedDescription)")
        }
    }

    private func instantiateClient(for info: SavedServerInfo) {
        let credential = KeychainTokenStore.readCredential(for: info.id)
        switch info.serverType {
        case .emby:
            let client = EmbyClient(
                id: info.id,
                serverName: info.name,
                serverBaseURL: info.url,
                accessToken: credential?.token,
                userId: credential?.userId
            )
            activeClients[info.id] = client
        case .jellyfin:
            let client = JellyfinClient(
                id: info.id,
                serverName: info.name,
                serverBaseURL: info.url,
                accessToken: credential?.token,
                userId: credential?.userId
            )
            activeClients[info.id] = client
        case .webDAV, .fnos:
            activeClients[info.id] = WebDAVClient(
                id: info.id,
                serverName: info.name,
                serverBaseURL: info.url,
                username: info.username,
                password: credential?.token
            )
        case .smb:
            guard let client = try? SMBMediaClient(
                id: info.id,
                serverName: info.name,
                serverBaseURL: info.url,
                username: info.username,
                password: credential?.token
            ) else {
                logger.error("Invalid SMB server URL for \(info.name)")
                return
            }
            activeClients[info.id] = client
        }
    }
}
