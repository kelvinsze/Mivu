import Foundation

/// Unified abstraction protocol for Emby / Jellyfin media servers.
public protocol MediaServerProtocol: Sendable {
    var serverName: String { get }
    var serverBaseURL: URL { get }
    var isAuthenticated: Bool { get }
    var playbackRequestHeaders: [String: String]? { get }

    func authenticate(username: String, password: String) async throws -> String
    func fetchLibraries() async throws -> [MediaLibrary]
    func fetchItems(libraryId: String, startIndex: Int, limit: Int) async throws -> [MediaItem]
    func fetchPlaybackInfo(itemId: String) async throws -> MediaPlaybackInfo
    func search(query: String, limit: Int) async throws -> [MediaItem]
    func fetchContinueWatching(limit: Int) async throws -> [MediaItem]
    func fetchPlaybackStreamURL(itemId: String) async throws -> URL
    func reportPlaybackProgress(itemId: String, position: TimeInterval, isPaused: Bool, isStopped: Bool, playSessionId: String?, mediaSourceId: String?) async throws

    func resolvePlaybackItem(_ item: MediaItem) async throws -> MediaItem
    func fetchItemDetail(itemId: String) async throws -> MediaItem?
    func fetchSimilarItems(itemId: String, limit: Int) async throws -> [MediaItem]
    func fetchPersonDetail(personId: String) async throws -> MediaPerson?
    func fetchPersonWorks(personId: String, personName: String) async throws -> [MediaItem]
    func toggleFavorite(itemId: String, isFavorite: Bool) async throws
    func markPlayed(itemId: String, isPlayed: Bool) async throws
}

public extension MediaServerProtocol {
    var playbackRequestHeaders: [String: String]? { nil }

    func fetchItemDetail(itemId: String) async throws -> MediaItem? { nil }
    func fetchSimilarItems(itemId: String, limit: Int) async throws -> [MediaItem] { [] }
    func fetchPersonDetail(personId: String) async throws -> MediaPerson? { nil }
    func fetchPersonWorks(personId: String, personName: String) async throws -> [MediaItem] { [] }
    func toggleFavorite(itemId: String, isFavorite: Bool) async throws {}
    func markPlayed(itemId: String, isPlayed: Bool) async throws {}

    func resolvePlaybackItem(_ item: MediaItem) async throws -> MediaItem {
        guard let itemId = item.serverItemID else { return item }
        let playback = try await fetchPlaybackInfo(itemId: itemId)
        var resolved = item
        resolved.url = playback.url
        if let headers = playbackRequestHeaders {
            resolved.headers = headers
        }
        if let resumePosition = playback.resumePosition {
            resolved.resumePosition = resumePosition
        }
        resolved.playSessionID = playback.playSessionId
        resolved.mediaSourceID = playback.mediaSourceId
        resolved.subtitleTracks = playback.subtitleTracks
        resolved.containerHint = playback.candidates.first?.containerHint
        resolved.videoCodecHint = playback.candidates.first?.videoCodecHint
        resolved.playbackAlternatives = playback.candidates.dropFirst().map {
            PlaybackAlternative(
                url: $0.url,
                containerHint: $0.containerHint,
                videoCodecHint: $0.videoCodecHint,
                playSessionID: $0.playSessionId,
                mediaSourceID: $0.mediaSourceId
            )
        }
        return resolved
    }
}

public enum MediaPlaybackMethod: String, Sendable {
    case directPlay
    case directStream
    case transcode
}

/// One server-provided playback option, kept in resolver preference order.
public struct MediaPlaybackCandidate: Sendable, Equatable {
    public let url: URL
    public let method: MediaPlaybackMethod
    public let playSessionId: String?
    public let mediaSourceId: String?
    public let containerHint: String?
    public let videoCodecHint: String?

    public init(url: URL, method: MediaPlaybackMethod, playSessionId: String? = nil, mediaSourceId: String? = nil, containerHint: String? = nil, videoCodecHint: String? = nil) {
        self.url = url
        self.method = method
        self.playSessionId = playSessionId
        self.mediaSourceId = mediaSourceId
        self.containerHint = containerHint
        self.videoCodecHint = videoCodecHint
    }
}

public struct MediaPlaybackInfo: Sendable, Equatable {
    public let itemId: String
    /// Ordered DirectPlay -> DirectStream -> Transcode candidates.
    public let candidates: [MediaPlaybackCandidate]

    // Compatibility projection for existing clients. These always describe the
    // first candidate selected by the resolver.
    public let url: URL
    public let method: MediaPlaybackMethod
    public let playSessionId: String?
    public let mediaSourceId: String?
    public let resumePosition: TimeInterval?
    public let subtitleTracks: [SubtitleTrack]

    public init(itemId: String, url: URL, method: MediaPlaybackMethod, playSessionId: String? = nil, mediaSourceId: String? = nil, resumePosition: TimeInterval? = nil, subtitleTracks: [SubtitleTrack] = []) {
        self.itemId = itemId
        self.candidates = [MediaPlaybackCandidate(url: url, method: method, playSessionId: playSessionId, mediaSourceId: mediaSourceId)]
        self.url = url
        self.method = method
        self.playSessionId = playSessionId
        self.mediaSourceId = mediaSourceId
        self.resumePosition = resumePosition
        self.subtitleTracks = subtitleTracks
    }

    public init?(itemId: String, candidates: [MediaPlaybackCandidate], resumePosition: TimeInterval? = nil, subtitleTracks: [SubtitleTrack] = []) {
        guard let selected = candidates.first else { return nil }
        self.itemId = itemId
        self.candidates = candidates
        self.url = selected.url
        self.method = selected.method
        self.playSessionId = selected.playSessionId
        self.mediaSourceId = selected.mediaSourceId
        self.resumePosition = resumePosition
        self.subtitleTracks = subtitleTracks
    }
}

/// Chooses the server-provided URL in Direct Play -> Direct Stream -> Transcode order.
public enum MediaPlaybackInfoSelector {
    public static func select(itemId: String, baseURL: URL, payload: [String: Any], streamPath: String? = nil) -> MediaPlaybackInfo? {
        guard let sources = payload["MediaSources"] as? [[String: Any]] else { return nil }
        var candidates: [(rank: Int, index: Int, value: MediaPlaybackCandidate)] = []
        var candidateIndex = 0
        let ticks = (payload["UserData"] as? [String: Any])?["PlaybackPositionTicks"] as? Double
        let resumePosition = ticks.map { $0 / 10_000_000 }

        for source in sources {
            let mediaSourceId = source["Id"] as? String
            let session = payload["PlaySessionId"] as? String ?? source["PlaySessionId"] as? String
            let sourceContainer = normalizedContainerHint(source["Container"] as? String)
            let videoCodec = normalizedVideoCodecHint(source)
            if (source["SupportsDirectPlay"] as? Bool) == true {
                var components = URLComponents(url: baseURL.appendingPathComponent(streamPath ?? "Videos/\(itemId)/stream"), resolvingAgainstBaseURL: false)
                components?.queryItems = [
                    URLQueryItem(name: "Static", value: "true"),
                    URLQueryItem(name: "MediaSourceId", value: mediaSourceId)
                ].filter { $0.value != nil }
                if let url = components?.url {
                    candidates.append((0, candidateIndex, MediaPlaybackCandidate(url: url, method: .directPlay, playSessionId: session, mediaSourceId: mediaSourceId, containerHint: sourceContainer, videoCodecHint: videoCodec)))
                    candidateIndex += 1
                }
            }
            let ordered: [(String, MediaPlaybackMethod, Bool)] = [
                ("DirectStreamUrl", .directStream, (source["SupportsDirectStream"] as? Bool) == true),
                ("TranscodingUrl", .transcode, (source["SupportsTranscoding"] as? Bool) == true)
            ]
            for (key, method, supported) in ordered {
                guard supported, let raw = source[key] as? String, !raw.isEmpty else { continue }
                let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL ?? URL(string: raw)
                guard let url else { continue }
                let rank = method == .directStream ? 1 : 2
                candidates.append((rank, candidateIndex, MediaPlaybackCandidate(url: url, method: method, playSessionId: session, mediaSourceId: mediaSourceId, containerHint: normalizedContainerHint(url.pathExtension), videoCodecHint: videoCodec)))
                candidateIndex += 1
            }
        }

        let orderedCandidates = candidates
            .sorted { lhs, rhs in lhs.rank == rhs.rank ? lhs.index < rhs.index : lhs.rank < rhs.rank }
            .map(\.value)
        return MediaPlaybackInfo(itemId: itemId, candidates: orderedCandidates, resumePosition: resumePosition, subtitleTracks: sources.first.map { subtitleTracks(from: $0, baseURL: baseURL, itemId: itemId, streamPath: streamPath) } ?? [])
    }

    private static func normalizedContainerHint(_ raw: String?) -> String? {
        guard let value = raw?
            .split(separator: ",")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !value.isEmpty else { return nil }
        return value == "matroska" ? "mkv" : value
    }

    private static func normalizedVideoCodecHint(_ source: [String: Any]) -> String? {
        let streams = source["MediaStreams"] as? [[String: Any]] ?? []
        let streamCodec = streams.first {
            ($0["Type"] as? String)?.lowercased() == "video"
        }?["Codec"] as? String
        let value = streamCodec ?? source["VideoCodec"] as? String
        return value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func subtitleTracks(from source: [String: Any], baseURL: URL, itemId: String, streamPath: String?) -> [SubtitleTrack] {
        let streams = source["MediaStreams"] as? [[String: Any]] ?? []
        return streams.enumerated().compactMap { offset, stream in
            guard (stream["Type"] as? String)?.lowercased() == "subtitle" else { return nil }
            let index = (stream["Index"] as? Int) ?? offset
            let codec = ((stream["Codec"] as? String) ?? (stream["Format"] as? String) ?? "").lowercased()
            let format: SubtitleFormat = codec.contains("vtt") ? .vtt : codec.contains("ass") ? .ass : codec.contains("ssa") ? .ssa : codec.contains("srt") ? .srt : codec.contains("pgs") ? .pgs : codec.contains("vob") ? .vobsub : .unknown
            let delivery = stream["DeliveryUrl"] as? String
            let deliveryMethod = (stream["DeliveryMethod"] as? String)?.lowercased()
            let isExternal = (stream["IsExternal"] as? Bool) == true
                || deliveryMethod == "external"
                || delivery != nil
            let subtitlePath: String = {
                let base = streamPath ?? "Videos/\(itemId)/stream"
                let parent = base.replacingOccurrences(of: "/stream", with: "")
                let suffix = format == .unknown ? "" : ".\(format.rawValue)"
                return "\(parent)/\(source["Id"] as? String ?? "")/Subtitles/\(index)/Stream\(suffix)"
            }()
            let url = isExternal
                ? delivery.flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL ?? URL(string: $0) }
                    ?? baseURL.appendingPathComponent(subtitlePath)
                : nil
            return SubtitleTrack(id: "\(index)", language: stream["Language"] as? String, title: stream["DisplayTitle"] as? String ?? stream["Title"] as? String, format: format, isDefault: stream["IsDefault"] as? Bool ?? false, isForced: stream["IsForced"] as? Bool ?? false, isEmbedded: !isExternal, url: url)
        }
    }
}

public struct MediaLibrary: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    public let collectionType: String?

    public init(id: String, name: String, collectionType: String? = nil) {
        self.id = id
        self.name = name
        self.collectionType = collectionType
    }
}
