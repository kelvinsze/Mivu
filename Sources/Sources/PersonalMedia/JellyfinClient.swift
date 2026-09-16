import Foundation
import OSLog

private let logger = Logger(subsystem: "com.kold.mivu", category: "JellyfinClient")

/// Jellyfin API client conforming to MediaServerProtocol.
public final class JellyfinClient: MediaServerProtocol, @unchecked Sendable {
    public let serverId: UUID
    public var serverName: String
    public var serverBaseURL: URL
    public private(set) var accessToken: String?
    public private(set) var userId: String?

    public var isAuthenticated: Bool {
        return accessToken != nil && !(accessToken?.isEmpty ?? true)
    }

    public var playbackRequestHeaders: [String: String]? { authorizationHeaders() }

    public init(
        id: UUID = UUID(),
        serverName: String,
        serverBaseURL: URL,
        accessToken: String? = nil,
        userId: String? = nil
    ) {
        self.serverId = id
        self.serverName = serverName
        self.serverBaseURL = serverBaseURL
        self.accessToken = accessToken
        self.userId = userId
    }

    // MARK: - Authentication

    public func authenticate(username: String, password: String) async throws -> String {
        let authURL = serverBaseURL.appendingPathComponent("Users/AuthenticateByName")
        var request = URLRequest(url: authURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Jellyfin client authorization header
        let authHeader = "MediaBrowser Client=\"Mivu\", Device=\"iPhone\", DeviceId=\"\(UPnPDevice.shared.uuid)\", Version=\"0.1.0\""
        request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")

        let body: [String: String] = ["Username": username, "Pw": password]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw MediaServerError.authenticationFailed
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["AccessToken"] as? String,
              let userObj = json["User"] as? [String: Any],
              let uid = userObj["Id"] as? String else {
            throw MediaServerError.invalidResponse
        }

        self.accessToken = token
        self.userId = uid
        logger.info("Jellyfin authenticated successfully for user: \(username)")
        return token
    }

    // MARK: - Media Libraries

    public func fetchLibraries() async throws -> [MediaLibrary] {
        guard let uid = userId else { throw MediaServerError.notAuthenticated }
        let url = serverBaseURL.appendingPathComponent("Users/\(uid)/Views")
        let request = makeAuthorizedRequest(url: url)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw MediaServerError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 500)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["Items"] as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item -> MediaLibrary? in
            guard let id = item["Id"] as? String, let name = item["Name"] as? String else { return nil }
            let colType = item["CollectionType"] as? String
            return MediaLibrary(id: id, name: name, collectionType: colType)
        }
    }

    // MARK: - Items in Library

    private static let detailedFields = "MediaSources,Overview,Path,MediaStreams,People,Genres,Studios,ProviderIds,PremiereDate,ProductionYear,CommunityRating,CriticRating,OfficialRating,Taglines"

    public func fetchItems(libraryId: String, startIndex: Int = 0, limit: Int = 50) async throws -> [MediaItem] {
        guard let uid = userId else { throw MediaServerError.notAuthenticated }
        return try await fetchMappedItems(userID: uid, queryItems: [
            URLQueryItem(name: "ParentId", value: libraryId),
            URLQueryItem(name: "StartIndex", value: "\(startIndex)"),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode,Video"),
            URLQueryItem(name: "Fields", value: Self.detailedFields)
        ])
    }

    public func fetchPlaybackStreamURL(itemId: String) async throws -> URL {
        (try await fetchPlaybackInfo(itemId: itemId)).url
    }

    public func search(query: String, limit: Int = 25) async throws -> [MediaItem] {
        guard let uid = userId else { throw MediaServerError.notAuthenticated }
        return try await fetchMappedItems(userID: uid, queryItems: [
            URLQueryItem(name: "SearchTerm", value: query), URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Recursive", value: "true"), URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode,Video"),
            URLQueryItem(name: "Fields", value: Self.detailedFields)
        ])
    }

    public func fetchContinueWatching(limit: Int = 25) async throws -> [MediaItem] {
        guard let uid = userId else { throw MediaServerError.notAuthenticated }
        return try await fetchMappedItems(userID: uid, queryItems: [
            URLQueryItem(name: "Limit", value: "\(limit)"), URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Filters", value: "IsResumable"), URLQueryItem(name: "SortBy", value: "DatePlayed"),
            URLQueryItem(name: "SortOrder", value: "Descending"), URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode,Video"),
            URLQueryItem(name: "Fields", value: Self.detailedFields)
        ])
    }

    public func fetchItemDetail(itemId: String) async throws -> MediaItem? {
        guard let uid = userId else { throw MediaServerError.notAuthenticated }
        var components = URLComponents(url: serverBaseURL.appendingPathComponent("Users/\(uid)/Items/\(itemId)"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "Fields", value: Self.detailedFields)]
        guard let url = components?.url else { throw MediaServerError.invalidURL }
        let (data, response) = try await URLSession.shared.data(for: makeAuthorizedRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw MediaServerError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 500)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return makeMediaItem(from: json)
    }

    public func fetchSimilarItems(itemId: String, limit: Int = 10) async throws -> [MediaItem] {
        guard let uid = userId else { throw MediaServerError.notAuthenticated }
        var components = URLComponents(url: serverBaseURL.appendingPathComponent("Items/\(itemId)/Similar"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "UserId", value: uid),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Fields", value: Self.detailedFields)
        ]
        guard let url = components?.url else { throw MediaServerError.invalidURL }
        let (data, response) = try await URLSession.shared.data(for: makeAuthorizedRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["Items"] as? [[String: Any]] else { return [] }
        return items.compactMap { makeMediaItem(from: $0) }
    }

    public func fetchPersonDetail(personId: String) async throws -> MediaPerson? {
        guard let uid = userId else { throw MediaServerError.notAuthenticated }
        var components = URLComponents(url: serverBaseURL.appendingPathComponent("Users/\(uid)/Items/\(personId)"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "Fields", value: Self.detailedFields)]
        guard let url = components?.url else { throw MediaServerError.invalidURL }
        let (data, response) = try await URLSession.shared.data(for: makeAuthorizedRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let pName = (json["Name"] as? String) ?? ""
        let overview = json["Overview"] as? String
        let premiereDate = json["PremiereDate"] as? String
        let endDate = json["EndDate"] as? String
        let locations = json["ProductionLocations"] as? [String]
        let birthPlace = locations?.first
        let providerIds = json["ProviderIds"] as? [String: String]
        let imgTag = json["PrimaryImageTag"] as? String
        let personImgURL: URL? = {
            guard let imgTag else { return nil }
            var c = URLComponents(url: serverBaseURL.appendingPathComponent("Items/\(personId)/Images/Primary"), resolvingAgainstBaseURL: false)
            c?.queryItems = [URLQueryItem(name: "maxWidth", value: "600"), URLQueryItem(name: "tag", value: imgTag)]
            return c?.url
        }()

        return MediaPerson(
            id: personId,
            name: pName,
            role: nil,
            type: json["Type"] as? String,
            imageURL: personImgURL,
            overview: overview,
            birthDate: premiereDate,
            deathDate: endDate,
            birthPlace: birthPlace,
            providerIds: providerIds
        )
    }

    public func fetchPersonWorks(personId: String, personName: String) async throws -> [MediaItem] {
        guard let uid = userId else { throw MediaServerError.notAuthenticated }
        var items: [MediaItem] = []

        if !personId.isEmpty {
            items = (try? await fetchMappedItems(userID: uid, queryItems: [
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,Episode"),
                URLQueryItem(name: "PersonIds", value: personId),
                URLQueryItem(name: "SortBy", value: "PremiereDate,ProductionYear,SortName"),
                URLQueryItem(name: "SortOrder", value: "Descending"),
                URLQueryItem(name: "Fields", value: Self.detailedFields)
            ])) ?? []
        }

        if items.isEmpty && !personName.isEmpty {
            items = (try? await fetchMappedItems(userID: uid, queryItems: [
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,Episode"),
                URLQueryItem(name: "Person", value: personName),
                URLQueryItem(name: "SortBy", value: "PremiereDate,ProductionYear,SortName"),
                URLQueryItem(name: "SortOrder", value: "Descending"),
                URLQueryItem(name: "Fields", value: Self.detailedFields)
            ])) ?? []
        }
        return items
    }

    public func toggleFavorite(itemId: String, isFavorite: Bool) async throws {
        guard let uid = userId else { throw MediaServerError.notAuthenticated }
        let endpoint = "Users/\(uid)/FavoriteItems/\(itemId)"
        let url = serverBaseURL.appendingPathComponent(endpoint)
        var request = makeAuthorizedRequest(url: url)
        request.httpMethod = isFavorite ? "POST" : "DELETE"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw MediaServerError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 500)
        }
    }

    public func markPlayed(itemId: String, isPlayed: Bool) async throws {
        guard let uid = userId else { throw MediaServerError.notAuthenticated }
        let endpoint = "Users/\(uid)/PlayedItems/\(itemId)"
        let url = serverBaseURL.appendingPathComponent(endpoint)
        var request = makeAuthorizedRequest(url: url)
        request.httpMethod = isPlayed ? "POST" : "DELETE"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw MediaServerError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 500)
        }
    }

    private func fetchMappedItems(userID: String, queryItems: [URLQueryItem]) async throws -> [MediaItem] {
        var components = URLComponents(url: serverBaseURL.appendingPathComponent("Users/\(userID)/Items"), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        guard let url = components?.url else { throw MediaServerError.invalidURL }
        let (data, response) = try await URLSession.shared.data(for: makeAuthorizedRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw MediaServerError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 500)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["Items"] as? [[String: Any]] else { return [] }
        return items.compactMap { makeMediaItem(from: $0) }
    }

    private func makeMediaItem(from dict: [String: Any]) -> MediaItem? {
        guard let id = dict["Id"] as? String, let name = dict["Name"] as? String else { return nil }
        let duration = ((dict["RunTimeTicks"] as? Double) ?? 0) / 10_000_000
        let playback = MediaPlaybackInfoSelector.select(itemId: id, baseURL: serverBaseURL, payload: dict, streamPath: "Videos/\(id)/stream")

        let userData = dict["UserData"] as? [String: Any]
        let isFav = userData?["IsFavorite"] as? Bool
        let isPlayed = userData?["Played"] as? Bool
        let ticks = (userData?["PlaybackPositionTicks"] as? Double) ?? 0
        let resume = playback?.resumePosition ?? (ticks > 0 ? ticks / 10_000_000 : nil)

        // People / Cast
        let peopleRaw = dict["People"] as? [[String: Any]] ?? []
        let people: [MediaPerson] = peopleRaw.compactMap { p in
            guard let pName = p["Name"] as? String else { return nil }
            let pId = (p["Id"] as? String) ?? UUID().uuidString
            let role = p["Role"] as? String
            let type = p["Type"] as? String
            let imgTag = p["PrimaryImageTag"] as? String
            let personImgURL: URL? = {
                guard let imgTag else { return nil }
                var c = URLComponents(url: serverBaseURL.appendingPathComponent("Items/\(pId)/Images/Primary"), resolvingAgainstBaseURL: false)
                c?.queryItems = [URLQueryItem(name: "maxWidth", value: "300"), URLQueryItem(name: "tag", value: imgTag)]
                return c?.url
            }()
            return MediaPerson(id: pId, name: pName, role: role, type: type, imageURL: personImgURL)
        }

        // Studios
        let studiosList = (dict["Studios"] as? [[String: Any]])?.compactMap { $0["Name"] as? String }

        // Streams and Media Sources
        let sources = dict["MediaSources"] as? [[String: Any]] ?? []
        let firstSource = sources.first
        let rawPath = firstSource?["Path"] as? String
        let fileName = rawPath?.components(separatedBy: "/").last?.components(separatedBy: "\\").last ?? (firstSource?["Name"] as? String)
        let fileSize = (firstSource?["Size"] as? Int64) ?? (firstSource?["Size"] as? Int).map { Int64($0) }
        let bitrate = firstSource?["Bitrate"] as? Int

        let streams = firstSource?["MediaStreams"] as? [[String: Any]] ?? []
        let videoStream = streams.first { ($0["Type"] as? String)?.lowercased() == "video" }
        let videoStreamInfo: VideoStreamInfo? = videoStream.map { s in
            VideoStreamInfo(
                title: s["DisplayTitle"] as? String ?? "\(s["Width"] ?? "")x\(s["Height"] ?? "") \(s["Codec"] ?? "")",
                codec: (s["Codec"] as? String)?.lowercased(),
                width: s["Width"] as? Int,
                height: s["Height"] as? Int,
                frameRate: (s["AverageFrameRate"] as? Double) ?? (s["RealFrameRate"] as? Double),
                bitRate: s["BitRate"] as? Int,
                dynamicRange: (s["VideoRange"] as? String) ?? (s["ColorTransfer"] as? String),
                profile: s["Profile"] as? String,
                level: (s["Level"] as? Double) ?? (s["Level"] as? Int).map { Double($0) },
                aspectRatio: s["AspectRatio"] as? String,
                isInterlaced: s["IsInterlaced"] as? Bool,
                colorPrimaries: s["ColorPrimaries"] as? String,
                colorSpace: s["ColorSpace"] as? String,
                colorTransfer: s["ColorTransfer"] as? String,
                bitDepth: s["BitDepth"] as? Int,
                pixelFormat: s["PixelFormat"] as? String
            )
        }

        let audioStreams = streams.filter { ($0["Type"] as? String)?.lowercased() == "audio" }
        let audioStreamInfos: [AudioStreamInfo] = audioStreams.enumerated().map { index, s in
            AudioStreamInfo(
                id: "\(s["Index"] as? Int ?? index)",
                title: s["DisplayTitle"] as? String ?? s["Title"] as? String,
                displayTitle: s["DisplayTitle"] as? String,
                language: s["Language"] as? String,
                channelLayout: s["ChannelLayout"] as? String,
                channels: s["Channels"] as? Int,
                codec: (s["Codec"] as? String)?.lowercased(),
                bitRate: s["BitRate"] as? Int,
                sampleRate: s["SampleRate"] as? Int,
                isExternal: s["IsExternal"] as? Bool ?? false,
                isDefault: s["IsDefault"] as? Bool ?? false
            )
        }

        return MediaItem(
            title: name,
            url: playback?.url ?? serverBaseURL.appendingPathComponent("Videos/\(id)/stream.mp4"),
            sourceType: .personalMedia,
            mimeType: "video/mp4",
            duration: duration > 0 ? duration : nil,
            posterUrl: posterURL(for: id, item: dict),
            headers: authorizationHeaders(),
            originator: serverName,
            serverID: serverId,
            serverItemID: id,
            playSessionID: playback?.playSessionId,
            mediaSourceID: playback?.mediaSourceId,
            resumePosition: resume,
            containerHint: playback?.candidates.first?.containerHint,
            videoCodecHint: playback?.candidates.first?.videoCodecHint,
            playbackAlternatives: playback?.candidates.dropFirst().map {
                PlaybackAlternative(url: $0.url, containerHint: $0.containerHint, videoCodecHint: $0.videoCodecHint, playSessionID: $0.playSessionId, mediaSourceID: $0.mediaSourceId)
            } ?? [],
            subtitleTracks: playback?.subtitleTracks,
            overview: dict["Overview"] as? String,
            backdropUrl: backdropURL(for: id, item: dict),
            logoUrl: logoURL(for: id, item: dict),
            rating: (dict["CommunityRating"] as? Double) ?? (dict["CriticRating"] as? Double),
            criticRating: dict["CriticRating"] as? Double,
            doubanRating: (dict["DoubanRating"] as? Double)
                ?? (dict["CustomRating"] as? Double)
                ?? ((dict["ProviderIds"] as? [String: Any])?["DoubanRating"] as? Double)
                ?? ((dict["ProviderIds"] as? [String: Any])?["DoubanScore"] as? Double)
                ?? (((dict["ProviderIds"] as? [String: Any])?["DoubanScore"] as? String).flatMap { Double($0) }),
            // CommunityRating is an unlabelled server aggregate, not necessarily IMDb.
            // Keep provider-specific fields empty until the unified ratings API fills them.
            imdbRating: dict["ImdbRating"] as? Double,
            rottenTomatoesRating: dict["RottenTomatoesRating"] as? Double,
            contentRating: dict["OfficialRating"] as? String,
            releaseDate: Self.formatPremiereDate(dict["PremiereDate"] as? String),
            year: dict["ProductionYear"] as? Int,
            genres: dict["Genres"] as? [String],
            studios: studiosList,
            isFavorite: isFav,
            isPlayed: isPlayed,
            people: people.isEmpty ? nil : people,
            videoStreamInfo: videoStreamInfo,
            audioStreamInfo: audioStreamInfos.isEmpty ? nil : audioStreamInfos,
            providerIds: Self.normalizedProviderIDs(dict["ProviderIds"]),
            fileName: fileName,
            fileSize: fileSize,
            bitrate: bitrate
        )
    }

    private func posterURL(for itemID: String, item: [String: Any]) -> URL? {
        let imageTags = item["ImageTags"] as? [String: Any]
        guard let tag = (imageTags?["Primary"] as? String) ?? (item["PrimaryImageTag"] as? String) else { return nil }
        var components = URLComponents(url: serverBaseURL.appendingPathComponent("Items/\(itemID)/Images/Primary"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "maxWidth", value: "360"),
            URLQueryItem(name: "quality", value: "90"),
            URLQueryItem(name: "tag", value: tag)
        ]
        return components?.url
    }

    private func backdropURL(for itemID: String, item: [String: Any]) -> URL? {
        let backdropTags = item["BackdropImageTags"] as? [String]
        let tag = backdropTags?.first ?? (item["ImageTags"] as? [String: Any])?["Backdrop"] as? String
        guard let tag else { return nil }
        var components = URLComponents(url: serverBaseURL.appendingPathComponent("Items/\(itemID)/Images/Backdrop/0"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "maxWidth", value: "1920"),
            URLQueryItem(name: "quality", value: "90"),
            URLQueryItem(name: "tag", value: tag)
        ]
        return components?.url
    }

    private func logoURL(for itemID: String, item: [String: Any]) -> URL? {
        let imageTags = item["ImageTags"] as? [String: Any]
        guard let tag = imageTags?["Logo"] as? String else { return nil }
        var components = URLComponents(url: serverBaseURL.appendingPathComponent("Items/\(itemID)/Images/Logo"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "maxWidth", value: "600"),
            URLQueryItem(name: "tag", value: tag)
        ]
        return components?.url
    }

    private static func formatPremiereDate(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let prefix = String(raw.prefix(10))
        let parts = prefix.split(separator: "-")
        if parts.count == 3 {
            return "\(parts[0])年 \(Int(parts[1]) ?? 1)月\(Int(parts[2]) ?? 1)日"
        }
        return prefix
    }

    public func fetchPlaybackInfo(itemId: String) async throws -> MediaPlaybackInfo {
        guard let uid = userId else { throw MediaServerError.notAuthenticated }
        var components = URLComponents(url: serverBaseURL.appendingPathComponent("Items/\(itemId)/PlaybackInfo"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "UserId", value: uid)]
        guard let url = components?.url else { throw MediaServerError.invalidURL }
        var request = makeAuthorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "EnableDirectPlay": true,
            "EnableDirectStream": true,
            "EnableTranscoding": true,
            "IsPlayback": true
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = MediaPlaybackInfoSelector.select(itemId: itemId, baseURL: serverBaseURL, payload: json, streamPath: "Videos/\(itemId)/stream") else {
            throw MediaServerError.invalidResponse
        }
        return info
    }

    public func reportPlaybackProgress(itemId: String, position: TimeInterval, isPaused: Bool, isStopped: Bool, playSessionId: String?, mediaSourceId: String?) async throws {
        let endpoint = isStopped ? "Sessions/Playing/Stopped" : "Sessions/Playing/Progress"
        let url = serverBaseURL.appendingPathComponent(endpoint)
        var request = makeAuthorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let ticks = Int64(position * 10_000_000.0)
        let body: [String: Any] = [
            "ItemId": itemId,
            "PositionTicks": ticks,
            "IsPaused": isPaused,
            "EventName": isStopped ? "stopped" : "timeupdate"
        ]
        var mutableBody = body
        if let playSessionId { mutableBody["PlaySessionId"] = playSessionId }
        if let mediaSourceId { mutableBody["MediaSourceId"] = mediaSourceId }
        request.httpBody = try JSONSerialization.data(withJSONObject: mutableBody)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw MediaServerError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 500)
        }
    }

    // MARK: - Helpers

    /// Jellyfin plugins can encode TMDb/TVDb IDs as numbers. Convert them to
    /// strings so the shared ratings client can use every available identity.
    private static func normalizedProviderIDs(_ value: Any?) -> [String: String]? {
        guard let values = value as? [String: Any] else { return nil }
        let normalized = values.reduce(into: [String: String]()) { result, entry in
            if let value = entry.value as? String, !value.isEmpty {
                result[entry.key] = value
            } else if let value = entry.value as? NSNumber {
                result[entry.key] = value.stringValue
            }
        }
        return normalized.isEmpty ? nil : normalized
    }

    private func makeAuthorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        for (key, val) in authorizationHeaders() {
            request.setValue(val, forHTTPHeaderField: key)
        }
        return request
    }

    private func authorizationHeaders() -> [String: String] {
        var headers = [
            "X-Emby-Authorization": "MediaBrowser Client=\"Mivu\", Device=\"iPhone\", DeviceId=\"\(UPnPDevice.shared.uuid)\", Version=\"0.1.0\""
        ]
        if let token = accessToken {
            headers["X-Emby-Token"] = token
        }
        return headers
    }
}

public enum MediaServerError: LocalizedError {
    case authenticationFailed
    case notAuthenticated
    case invalidResponse
    case invalidURL
    case requestFailed(statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed: return "Server authentication failed. Please check your username and password."
        case .notAuthenticated: return "User is not authenticated."
        case .invalidResponse: return "Received invalid response format from media server."
        case .invalidURL: return "The media server URL is invalid."
        case .requestFailed(let code): return "Server returned error code: HTTP \(code)"
        }
    }
}
