import Foundation

/// Lifecycle playback status of Mivu Player.
public enum PlaybackStatus: String, Codable, Sendable {
    case idle = "IDLE"
    case loading = "LOADING"
    case playing = "PLAYING"
    case paused = "PAUSED_PLAYBACK"
    case stopped = "STOPPED"
    case failed = "FAILED"
}

/// Represents the active playback session snapshot for UI observation and DLNA/CarPlay sync.
public struct PlaybackSession: Equatable, Sendable {
    public var currentItem: MediaItem?
    public var status: PlaybackStatus
    public var currentTime: TimeInterval
    public var duration: TimeInterval
    public var bufferedTime: TimeInterval
    public var playbackRate: Float
    public var isMuted: Bool
    public var volume: Float
    public var errorMessage: String?

    public init(
        currentItem: MediaItem? = nil,
        status: PlaybackStatus = .idle,
        currentTime: TimeInterval = 0,
        duration: TimeInterval = 0,
        bufferedTime: TimeInterval = 0,
        playbackRate: Float = 1.0,
        isMuted: Bool = false,
        volume: Float = 1.0,
        errorMessage: String? = nil
    ) {
        self.currentItem = currentItem
        self.status = status
        self.currentTime = currentTime
        self.duration = duration
        self.bufferedTime = bufferedTime
        self.playbackRate = playbackRate
        self.isMuted = isMuted
        self.volume = volume
        self.errorMessage = errorMessage
    }

    public var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    public var isLiveStream: Bool {
        return duration.isInfinite || duration.isNaN
    }
}
