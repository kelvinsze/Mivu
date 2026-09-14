import Foundation

/// Defines the origin or type of a playable media stream in Mivu.
public enum MediaSourceType: String, Codable, Sendable {
    case directUrl = "direct_url"
    case dlna = "dlna"
    case personalMedia = "personal_media"
    case testStream = "test_stream"
}

/// A server-provided stream that can be tried if the current stream fails.
public struct PlaybackAlternative: Codable, Equatable, Sendable {
    public let url: URL
    public let containerHint: String?
    public let videoCodecHint: String?
    public let playSessionID: String?
    public let mediaSourceID: String?

    public init(url: URL, containerHint: String? = nil, videoCodecHint: String? = nil, playSessionID: String? = nil, mediaSourceID: String? = nil) {
        self.url = url
        self.containerHint = containerHint
        self.videoCodecHint = videoCodecHint
        self.playSessionID = playSessionID
        self.mediaSourceID = mediaSourceID
    }
}

public enum SubtitleFormat: String, Codable, Sendable {
    case srt, vtt, ass, ssa, pgs, vobsub, unknown
}

public struct SubtitleTrack: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let language: String?
    public let title: String?
    public let format: SubtitleFormat
    public let isDefault: Bool
    public let isForced: Bool
    public let isEmbedded: Bool
    public let url: URL?

    public init(id: String, language: String? = nil, title: String? = nil, format: SubtitleFormat = .unknown,
                isDefault: Bool = false, isForced: Bool = false, isEmbedded: Bool = true, url: URL? = nil) {
        self.id = id; self.language = language; self.title = title; self.format = format
        self.isDefault = isDefault; self.isForced = isForced; self.isEmbedded = isEmbedded; self.url = url
    }
}

/// Cast, crew, or director entry for media items.
public struct MediaPerson: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let role: String?
    public let type: String?
    public let imageURL: URL?
    public var overview: String?
    public var birthDate: String?
    public var deathDate: String?
    public var birthPlace: String?
    public var providerIds: [String: String]?

    public init(
        id: String = UUID().uuidString,
        name: String,
        role: String? = nil,
        type: String? = nil,
        imageURL: URL? = nil,
        overview: String? = nil,
        birthDate: String? = nil,
        deathDate: String? = nil,
        birthPlace: String? = nil,
        providerIds: [String: String]? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.type = type
        self.imageURL = imageURL
        self.overview = overview
        self.birthDate = birthDate
        self.deathDate = deathDate
        self.birthPlace = birthPlace
        self.providerIds = providerIds
    }
}

/// Detailed technical specs of a video stream (codec, resolution, color space, etc.).
public struct VideoStreamInfo: Codable, Equatable, Hashable, Sendable {
    public var title: String?
    public var codec: String?
    public var width: Int?
    public var height: Int?
    public var frameRate: Double?
    public var bitRate: Int?
    public var dynamicRange: String?
    public var profile: String?
    public var level: Double?
    public var aspectRatio: String?
    public var isInterlaced: Bool?
    public var colorPrimaries: String?
    public var colorSpace: String?
    public var colorTransfer: String?
    public var bitDepth: Int?
    public var pixelFormat: String?

    public init(
        title: String? = nil,
        codec: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        frameRate: Double? = nil,
        bitRate: Int? = nil,
        dynamicRange: String? = nil,
        profile: String? = nil,
        level: Double? = nil,
        aspectRatio: String? = nil,
        isInterlaced: Bool? = nil,
        colorPrimaries: String? = nil,
        colorSpace: String? = nil,
        colorTransfer: String? = nil,
        bitDepth: Int? = nil,
        pixelFormat: String? = nil
    ) {
        self.title = title
        self.codec = codec
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitRate = bitRate
        self.dynamicRange = dynamicRange
        self.profile = profile
        self.level = level
        self.aspectRatio = aspectRatio
        self.isInterlaced = isInterlaced
        self.colorPrimaries = colorPrimaries
        self.colorSpace = colorSpace
        self.colorTransfer = colorTransfer
        self.bitDepth = bitDepth
        self.pixelFormat = pixelFormat
    }
}

/// Detailed technical specs of an audio stream.
public struct AudioStreamInfo: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public var title: String?
    public var displayTitle: String?
    public var language: String?
    public var channelLayout: String?
    public var channels: Int?
    public var codec: String?
    public var bitRate: Int?
    public var sampleRate: Int?
    public var isExternal: Bool
    public var isDefault: Bool

    public init(
        id: String = UUID().uuidString,
        title: String? = nil,
        displayTitle: String? = nil,
        language: String? = nil,
        channelLayout: String? = nil,
        channels: Int? = nil,
        codec: String? = nil,
        bitRate: Int? = nil,
        sampleRate: Int? = nil,
        isExternal: Bool = false,
        isDefault: Bool = false
    ) {
        self.id = id
        self.title = title
        self.displayTitle = displayTitle
        self.language = language
        self.channelLayout = channelLayout
        self.channels = channels
        self.codec = codec
        self.bitRate = bitRate
        self.sampleRate = sampleRate
        self.isExternal = isExternal
        self.isDefault = isDefault
    }
}

/// Represents a single playable media item.
public struct MediaItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var url: URL
    public var sourceType: MediaSourceType
    public var mimeType: String?
    public var duration: TimeInterval?
    public var posterUrl: URL?
    public var headers: [String: String]?
    public var originator: String?
    public var serverID: UUID?
    public var serverItemID: String?
    public var playSessionID: String?
    public var mediaSourceID: String?
    public var resumePosition: TimeInterval?
    public var containerHint: String?
    public var videoCodecHint: String?
    public var playbackAlternatives: [PlaybackAlternative]?
    public var subtitleTracks: [SubtitleTrack]?
    public var createdAt: Date

    // Rich detail & metadata fields
    public var overview: String?
    public var backdropUrl: URL?
    public var logoUrl: URL?
    public var rating: Double?
    public var criticRating: Double?
    public var doubanRating: Double?
    public var imdbRating: Double?
    public var rottenTomatoesRating: Double?
    public var contentRating: String?
    public var releaseDate: String?
    public var year: Int?
    public var genres: [String]?
    public var studios: [String]?
    public var isFavorite: Bool?
    public var isPlayed: Bool?
    public var people: [MediaPerson]?
    public var videoStreamInfo: VideoStreamInfo?
    public var audioStreamInfo: [AudioStreamInfo]?
    public var providerIds: [String: String]?
    public var fileName: String?
    public var fileSize: Int64?
    public var bitrate: Int?

    public init(
        id: UUID = UUID(),
        title: String,
        url: URL,
        sourceType: MediaSourceType = .directUrl,
        mimeType: String? = nil,
        duration: TimeInterval? = nil,
        posterUrl: URL? = nil,
        headers: [String: String]? = nil,
        originator: String? = nil,
        serverID: UUID? = nil,
        serverItemID: String? = nil,
        playSessionID: String? = nil,
        mediaSourceID: String? = nil,
        resumePosition: TimeInterval? = nil,
        containerHint: String? = nil,
        videoCodecHint: String? = nil,
        playbackAlternatives: [PlaybackAlternative] = [],
        subtitleTracks: [SubtitleTrack]? = nil,
        createdAt: Date = Date(),
        overview: String? = nil,
        backdropUrl: URL? = nil,
        logoUrl: URL? = nil,
        rating: Double? = nil,
        criticRating: Double? = nil,
        doubanRating: Double? = nil,
        imdbRating: Double? = nil,
        rottenTomatoesRating: Double? = nil,
        contentRating: String? = nil,
        releaseDate: String? = nil,
        year: Int? = nil,
        genres: [String]? = nil,
        studios: [String]? = nil,
        isFavorite: Bool? = nil,
        isPlayed: Bool? = nil,
        people: [MediaPerson]? = nil,
        videoStreamInfo: VideoStreamInfo? = nil,
        audioStreamInfo: [AudioStreamInfo]? = nil,
        providerIds: [String: String]? = nil,
        fileName: String? = nil,
        fileSize: Int64? = nil,
        bitrate: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.sourceType = sourceType
        self.mimeType = mimeType
        self.duration = duration
        self.posterUrl = posterUrl
        self.headers = headers
        self.originator = originator
        self.serverID = serverID
        self.serverItemID = serverItemID
        self.playSessionID = playSessionID
        self.mediaSourceID = mediaSourceID
        self.resumePosition = resumePosition
        self.containerHint = containerHint
        self.videoCodecHint = videoCodecHint
        self.playbackAlternatives = playbackAlternatives
        self.subtitleTracks = subtitleTracks
        self.createdAt = createdAt
        self.overview = overview
        self.backdropUrl = backdropUrl
        self.logoUrl = logoUrl
        self.rating = rating
        self.criticRating = criticRating
        self.doubanRating = doubanRating
        self.imdbRating = imdbRating
        self.rottenTomatoesRating = rottenTomatoesRating
        self.contentRating = contentRating
        self.releaseDate = releaseDate
        self.year = year
        self.genres = genres
        self.studios = studios
        self.isFavorite = isFavorite
        self.isPlayed = isPlayed
        self.people = people
        self.videoStreamInfo = videoStreamInfo
        self.audioStreamInfo = audioStreamInfo
        self.providerIds = providerIds
        self.fileName = fileName
        self.fileSize = fileSize
        self.bitrate = bitrate
    }

    public var effectiveDoubanRating: Double? {
        doubanRating
    }

    public var effectiveImdbRating: Double? {
        imdbRating ?? rating
    }

    public var effectiveRottenTomatoesRating: Double? {
        rottenTomatoesRating ?? criticRating
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public func withoutSensitiveHeaders() -> MediaItem {
        var copy = self
        copy.headers = nil
        copy.playSessionID = nil
        copy.mediaSourceID = nil
        copy.playbackAlternatives = nil
        return copy
    }

    @discardableResult
    public mutating func advanceToNextPlaybackAlternative() -> Bool {
        guard var alternatives = playbackAlternatives, !alternatives.isEmpty else { return false }
        let next = alternatives.removeFirst()
        playbackAlternatives = alternatives
        url = next.url
        containerHint = next.containerHint
        videoCodecHint = next.videoCodecHint
        playSessionID = next.playSessionID
        mediaSourceID = next.mediaSourceID
        return true
    }
}

extension MediaItem {
    /// Universally accessible test streams with rich sample metadata
    public static var sampleItems: [MediaItem] { sampleStreams }
    public static let sampleStreams: [MediaItem] = [
        MediaItem(
            title: "Apple 官方 16:9 HLS 测试流 (高清晰·自适应)",
            url: URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8")!,
            sourceType: .testStream,
            mimeType: "application/x-mpegURL",
            duration: 1800,
            posterUrl: URL(string: "https://images.unsplash.com/photo-1536440136628-849c177e76a1?w=800&q=80"),
            overview: "Apple 官方 HTTP Live Streaming (HLS) 权威测试视频流，包含自适应多码率分片、立体声音频与内嵌字幕，用于验证现代媒体播放器的流式缓冲与分辨率自适应平滑切换。",
            backdropUrl: URL(string: "https://images.unsplash.com/photo-1489599849927-2ee91cede3ba?w=1920&q=80"),
            rating: 9.2,
            criticRating: 88,
            contentRating: "ALL",
            releaseDate: "2024年 10月",
            year: 2024,
            genres: ["流媒体", "技术基准", "4K HDR"],
            studios: ["Apple Inc.", "Akamai Technologies"],
            videoStreamInfo: VideoStreamInfo(
                title: "1080p H264 Adaptive",
                codec: "h264",
                width: 1920,
                height: 1080,
                frameRate: 29.97,
                bitRate: 4500000,
                dynamicRange: "SDR",
                profile: "High",
                level: 4.1,
                aspectRatio: "16:9",
                isInterlaced: false,
                colorPrimaries: "bt709",
                colorSpace: "bt709",
                colorTransfer: "bt709",
                bitDepth: 8,
                pixelFormat: "yuv420p"
            ),
            audioStreamInfo: [
                AudioStreamInfo(id: "1", title: "English Stereo (AAC)", displayTitle: "English AAC", language: "English", channelLayout: "Stereo", channels: 2, codec: "aac", bitRate: 192000, sampleRate: 48000, isDefault: true)
            ],
            fileName: "bipbop_16x9_variant.m3u8",
            fileSize: 485000000,
            bitrate: 4500000
        ),
        MediaItem(
            title: "MDN Flower WebM 测试片段 (MPV 验证)",
            url: URL(string: "https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.webm")!,
            sourceType: .testStream,
            mimeType: "video/webm",
            duration: 15,
            posterUrl: URL(string: "https://images.unsplash.com/photo-1490750967868-88aa4486c946?w=800&q=80"),
            containerHint: "webm",
            overview: "Mozilla 开发者网络 (MDN) 官方标准 WebM 视频片段，用于验证 MPV 硬件加速、VP8/VP9 软硬解切换与色彩空间映射。",
            backdropUrl: URL(string: "https://images.unsplash.com/photo-1508615039623-a25605d2b022?w=1920&q=80"),
            rating: 8.5,
            criticRating: 80,
            contentRating: "G",
            releaseDate: "2023年",
            year: 2023,
            genres: ["自然", "微距", "色彩测试"],
            studios: ["Mozilla Developer Network"],
            videoStreamInfo: VideoStreamInfo(
                title: "1080p VP8",
                codec: "vp8",
                width: 1920,
                height: 1080,
                frameRate: 30.0,
                bitRate: 3200000,
                dynamicRange: "SDR",
                aspectRatio: "16:9",
                isInterlaced: false,
                bitDepth: 8,
                pixelFormat: "yuv420p"
            ),
            audioStreamInfo: [
                AudioStreamInfo(id: "1", title: "Vorbis Stereo", displayTitle: "Vorbis", language: "English", channelLayout: "Stereo", channels: 2, codec: "vorbis", bitRate: 128000, sampleRate: 44100, isDefault: true)
            ],
            fileName: "flower.webm",
            fileSize: 6200000,
            bitrate: 3200000
        ),
        MediaItem(
            title: "大雄兔 Big Buck Bunny (W3C 标准 MP4 直链)",
            url: URL(string: "https://www.w3schools.com/html/mov_bbb.mp4")!,
            sourceType: .testStream,
            mimeType: "video/mp4",
            duration: 596,
            posterUrl: URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/c/c5/Big_buck_bunny_poster_big.jpg/640px-Big_buck_bunny_poster_big.jpg"),
            overview: "Blender 基金会制作的著名开源 3D 动画短片。一只体型庞大却性情温柔祥和的大白兔，面对三只调皮捣蛋的森林恶霸小动物，决心用智慧和陷阱展开一场滑稽且精彩的森林大反击。",
            backdropUrl: URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a7/Big_Buck_Bunny_thumbnail_vlc.png/1280px-Big_Buck_Bunny_thumbnail_vlc.png"),
            rating: 8.4,
            criticRating: 82,
            doubanRating: 8.1,
            imdbRating: 7.2,
            rottenTomatoesRating: 82,
            contentRating: "G",
            releaseDate: "2008年 4月10日",
            year: 2008,
            genres: ["动画", "喜剧", "短片"],
            studios: ["Blender Foundation", "Peach Open Movie Project"],
            people: [
                MediaPerson(
                    id: "p1",
                    name: "Sacha Goedegebure",
                    role: "导演 / 编剧",
                    type: "Director",
                    imageURL: URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a2/Sacha_Goedegebure.jpg/480px-Sacha_Goedegebure.jpg"),
                    overview: "Sacha Goedegebure（网名 Saschart）是知名的 3D 动画艺术家与数字插画师，作为核心导演执导了开源 3D 动画电影《大白兔》（Big Buck Bunny），在开源艺术与计算机图形学领域享有盛誉。",
                    birthPlace: "荷兰"
                ),
                MediaPerson(
                    id: "p2",
                    name: "Ton Roosendaal",
                    role: "制片人",
                    type: "Producer",
                    imageURL: URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/d/d4/Ton_Roosendaal_-_SIGGRAPH_2019.jpg/480px-Ton_Roosendaal_-_SIGGRAPH_2019.jpg"),
                    overview: "Ton Roosendaal 是荷兰著名软件开发者与电影制片人，Blender 开源 3D 创作套件的首席创作者，Blender 基金会创始人兼主席。他主导了《Elephants Dream》、《大白兔》、《Sintel》等一系列开源电影项目，推动了全球开放电影与开源 CG 技术的蓬勃发展。",
                    birthDate: "1960-03-20",
                    birthPlace: "荷兰海尔德兰省"
                )
            ],
            videoStreamInfo: VideoStreamInfo(
                title: "1080p H264",
                codec: "h264",
                width: 1920,
                height: 1080,
                frameRate: 24.0,
                bitRate: 5200000,
                dynamicRange: "SDR",
                profile: "High",
                level: 4.0,
                aspectRatio: "16:9",
                isInterlaced: false,
                colorPrimaries: "bt709",
                colorSpace: "bt709",
                colorTransfer: "bt709",
                bitDepth: 8,
                pixelFormat: "yuv420p"
            ),
            audioStreamInfo: [
                AudioStreamInfo(id: "1", title: "English Stereo (AAC)", displayTitle: "English AAC", language: "English", channelLayout: "Stereo", channels: 2, codec: "aac", bitRate: 192000, sampleRate: 48000, isDefault: true)
            ],
            providerIds: ["Imdb": "tt1254207", "Tmdb": "10378"],
            fileName: "mov_bbb.mp4",
            fileSize: 158000000,
            bitrate: 5200000
        ),
        MediaItem(
            title: "Sintel 动画电影预告片 (W3C 标准 MP4 直链)",
            url: URL(string: "https://media.w3.org/2010/05/sintel/trailer.mp4")!,
            sourceType: .testStream,
            mimeType: "video/mp4",
            duration: 52,
            posterUrl: URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/8/8f/Sintel_poster.jpg/640px-Sintel_poster.jpg"),
            overview: "Blender 基金会打造的开源奇幻史诗动画短片。孤傲坚强的女孩 Sintel 在荒野风雪中救起了一只受重伤的小飞龙并悉心照料。当小龙被成年巨龙掠走后，她义无反顾地踏上孤独而艰险的漫漫寻友征途。",
            backdropUrl: URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/f/f6/Sintel_render.jpg/1280px-Sintel_render.jpg"),
            rating: 8.8,
            criticRating: 85,
            doubanRating: 8.4,
            imdbRating: 7.4,
            rottenTomatoesRating: 88,
            contentRating: "PG",
            releaseDate: "2010年 9月27日",
            year: 2010,
            genres: ["奇幻", "冒险", "史诗"],
            studios: ["Blender Foundation", "Durian Open Movie Project"],
            people: [
                MediaPerson(
                    id: "s1",
                    name: "Colin Levy",
                    role: "导演",
                    type: "Director",
                    imageURL: URL(string: "https://images.squarespace-cdn.com/content/v1/51b3696ee4b0c265e3bb32c0/1449767746536-T8Z4HQ8Q41Z7I6Z4I61V/colin_levy_headshot.jpg"),
                    overview: "Colin Levy 是美国独立电影导演与视觉特效艺术家，曾就职于皮克斯动画工作室（Pixar Animation Studios），参与制作了多部知名皮克斯长片。作为 Blender 基金会 Durian 开放电影项目导演，他执导了享誉全球的开源奇幻动画短片《Sintel》。",
                    birthPlace: "美国俄亥俄州"
                ),
                MediaPerson(
                    id: "s2",
                    name: "Halina Reijn",
                    role: "Sintel (配音)",
                    type: "Actor",
                    imageURL: URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/c/cb/Halina_Reijn_%282019%29.jpg/480px-Halina_Reijn_%282019%29.jpg"),
                    overview: "Halina Reijn 是荷兰知名女演员、导演及作家，多次荣获荷兰电影节金牛奖（Golden Calf）。她曾在保罗·范霍文执导的二战惊悚片《黑皮书》中奉献了精湛演技，并在 Blender 基金会的动画短片《Sintel》中为女主角 Sintel 倾情献声配音。",
                    birthDate: "1975-11-10",
                    birthPlace: "荷兰阿姆斯特丹"
                )
            ],
            videoStreamInfo: VideoStreamInfo(
                title: "1080p H264",
                codec: "h264",
                width: 1920,
                height: 1080,
                frameRate: 24.0,
                bitRate: 4800000,
                dynamicRange: "SDR",
                profile: "High",
                level: 4.0,
                aspectRatio: "16:9",
                isInterlaced: false,
                colorPrimaries: "bt709",
                colorSpace: "bt709",
                colorTransfer: "bt709",
                bitDepth: 8,
                pixelFormat: "yuv420p"
            ),
            audioStreamInfo: [
                AudioStreamInfo(id: "1", title: "Surround 5.1 (AAC)", displayTitle: "English AAC 5.1", language: "English", channelLayout: "5.1", channels: 6, codec: "aac", bitRate: 384000, sampleRate: 48000, isDefault: true)
            ],
            providerIds: ["Imdb": "tt1727588", "Tmdb": "45745"],
            fileName: "trailer.mp4",
            fileSize: 45000000,
            bitrate: 4800000
        ),
        MediaItem(
            title: "高清 MP4 测试短片 1 (国内高速 CDN 直链)",
            url: URL(string: "https://v-cdn.zjol.com.cn/280443.mp4")!,
            sourceType: .testStream,
            mimeType: "video/mp4",
            duration: 30,
            posterUrl: URL(string: "https://images.unsplash.com/photo-1518791841217-8f162f1e1131?w=800&q=80"),
            overview: "国内主流高速云 CDN 节点加速的 MP4 H.264 基准测试视频，极速加载，适合测试国内弱网以及低延迟流媒体加载。",
            backdropUrl: URL(string: "https://images.unsplash.com/photo-1518791841217-8f162f1e1131?w=1920&q=80"),
            rating: 7.8,
            year: 2024,
            genres: ["CDN 直链", "基准测试"],
            videoStreamInfo: VideoStreamInfo(
                title: "1080p H264",
                codec: "h264",
                width: 1920,
                height: 1080,
                frameRate: 25.0,
                bitRate: 3500000,
                dynamicRange: "SDR"
            )
        ),
        MediaItem(
            title: "高清 MP4 测试短片 2 (国内高速 CDN 直链)",
            url: URL(string: "https://v-cdn.zjol.com.cn/276982.mp4")!,
            sourceType: .testStream,
            mimeType: "video/mp4",
            duration: 35,
            posterUrl: URL(string: "https://images.unsplash.com/photo-1574717024653-61fd2cf4d44d?w=800&q=80"),
            overview: "国内主流云端分发的多媒体测试素材，包含生动的高对比度动态场景，适合用于验证屏幕色彩与渲染帧率表现。",
            backdropUrl: URL(string: "https://images.unsplash.com/photo-1574717024653-61fd2cf4d44d?w=1920&q=80"),
            rating: 7.9,
            year: 2024,
            genres: ["CDN 直链", "色彩基准"],
            videoStreamInfo: VideoStreamInfo(
                title: "1080p H264",
                codec: "h264",
                width: 1920,
                height: 1080,
                frameRate: 25.0,
                bitRate: 3800000,
                dynamicRange: "SDR"
            )
        )
    ]
}
