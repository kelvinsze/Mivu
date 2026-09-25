import Foundation
import AVFoundation
import MediaPlayer
import OSLog
import Combine
import UIKit
import CarPlay

private let logger = Logger(subsystem: "com.kold.mivu", category: "PlayerService")

/// Core video playback service for Mivu, managing AVPlayer, audio session,
/// Now Playing info, and remote control events.
@MainActor
public final class PlayerService: ObservableObject {
    public static let shared = PlayerService()

    @Published public private(set) var session: PlaybackSession = PlaybackSession()
    @Published public private(set) var player: AVPlayer
    @Published public private(set) var renderSurfaceKind: PlaybackRenderSurfaceKind = .nativeAVPlayer
    @Published public var videoGravity: AVLayerVideoGravity = .resizeAspect
    @Published public var selectedSpeed: Float = 1.0
    public static let subtitleUserScaleKey = "mivu_subtitle_user_scale"
    public static let subtitleAutoPortraitKey = "mivu_subtitle_auto_portrait"
    public static let subtitleDelayKey = "mivu_subtitle_delay"
    public static let subtitleVerticalOffsetKey = "mivu_subtitle_vertical_offset"
    public static let playbackRateLimitMbpsKey = "mivu_playback_rate_limit_mbps"
    public static let playbackCacheLimitMBKey = "mivu_playback_cache_limit_mb"
    public static let rewindOnResumeSecondsKey = "mivu_rewind_on_resume_seconds"
    public static let skipIntroSecondsKey = "mivu_skip_intro_seconds"
    public static let skipOutroSecondsKey = "mivu_skip_outro_seconds"
    public static let voiceBoostKey = "mivu_voice_boost_enabled"
    public static let volumeBoostKey = "mivu_volume_boost"

    @Published public private(set) var subtitleTracks: [SubtitleTrack] = []
    @Published public private(set) var selectedSubtitleTrack: SubtitleTrack?
    @Published public private(set) var secondarySubtitleTrack: SubtitleTrack?
    @Published public private(set) var audioTracks: [AudioTrack] = []
    @Published public private(set) var selectedAudioTrack: AudioTrack?
    @Published public private(set) var subtitleUserScale: Double
    @Published public private(set) var subtitleAutoPortraitScale: Bool
    @Published public private(set) var subtitleDelay: Double = 0.0
    @Published public private(set) var subtitleVerticalOffset: Int = 100
    @Published public private(set) var chapters: [PlaybackChapter] = []
    @Published public private(set) var currentPlaylist: [MediaItem] = []
    @Published public private(set) var playbackRateLimitMbps: Int
    @Published public private(set) var playbackCacheLimitMB: Int
    @Published public private(set) var downloadSpeed: Double = 0
    @Published public private(set) var rewindOnResumeSeconds: Double
    @Published public private(set) var skipIntroSeconds: Double
    @Published public private(set) var skipOutroSeconds: Double
    @Published public private(set) var isVoiceBoostEnabled: Bool
    @Published public private(set) var volumeBoost: Float
    @Published public private(set) var isAudioOnlyMode: Bool = false
    @Published public private(set) var showSkipOutroPrompt: Bool = false
    @Published public var isShowingPlayer: Bool = false
    @Published public var isCarPlayConnected: Bool = false
    @Published public private(set) var isCarPlayVideoPlaybackAvailable: Bool = false
    @Published public private(set) var isExternalPlaybackActive: Bool = false

    /// Indicates whether CarPlay projection, external display, or CarPlay casting is active.
    public var isCarPlayActive: Bool {
        if isCarPlayConnected || isExternalPlaybackActive { return true }
        if CarPlaySceneDelegate.shared?.isConnected == true { return true }
        return UIApplication.shared.connectedScenes.contains { scene in
            scene.session.role == .carTemplateApplication
                || scene.session.role.rawValue == "CPTemplateApplicationSceneSessionRoleApplication"
        }
    }

    public func setCarPlayVideoPlaybackAvailable(_ isAvailable: Bool) {
        isCarPlayVideoPlaybackAvailable = isAvailable
    }

    // AB Repeat
    @Published public private(set) var repeatPointA: TimeInterval? = nil
    @Published public private(set) var repeatPointB: TimeInterval? = nil
    @Published public private(set) var isABRepeatActive: Bool = false

    private var lastPauseTimestamp: Date?
    private var hasSkippedIntroForCurrentItem = false

    private var telemetryTask: Task<Void, Never>?

    private let nativeEngine: AVPlayerEngine
    private var mpvEngine: MPVPlayerEngine?
    private var engine: PlayerEngine
    private var engineTask: Task<Void, Never>?
    private var engineGeneration = 0
    private var cancellables = Set<AnyCancellable>()
    private var lastProgressReportDate = Date.distantPast
    private var lastHistoryUpdateDate = Date.distantPast
    private var castTraceGeneration = 0
    private var lastTracePlayerTime: TimeInterval?
    private var lastTraceSnapshotAt: TimeInterval = 0
    private var pendingSeekOrigin: (target: TimeInterval, origin: String)?
    private var firstSOAPSeekPending = false
    private var castLoadStartedAt: Date?
    private var castPlaybackStartedAt: Date?
    private var castFirstFrameAt: Date?
    private var castBufferWaitStartedAt: Date?
    private var castTotalBufferWait: TimeInterval = 0
    private var castBufferWaitCount = 0
    private var lastCastMetricSampleAt = Date.distantPast
    private var suppressLockedScreenCastPause = false
    private var mpvFallbackAttempted = false
    private var transcodeFallbackAttempted = false
    private var mpvInitialLoadRetryAttempted = false
    private var requiresNativePlayback = false
    private var isPortraitOrientation = false

    public init() {
        let savedScale = UserDefaults.standard.double(forKey: Self.subtitleUserScaleKey)
        let initialScale = savedScale > 0 ? savedScale : 1.0
        self.subtitleUserScale = initialScale
        if let savedAutoPortrait = UserDefaults.standard.object(forKey: Self.subtitleAutoPortraitKey) as? Bool {
            self.subtitleAutoPortraitScale = savedAutoPortrait
        } else {
            self.subtitleAutoPortraitScale = true
        }
        self.subtitleDelay = UserDefaults.standard.double(forKey: Self.subtitleDelayKey)
        let savedSubPos = UserDefaults.standard.integer(forKey: Self.subtitleVerticalOffsetKey)
        self.subtitleVerticalOffset = (savedSubPos >= 50 && savedSubPos <= 100) ? savedSubPos : 100

        #if MIVU_LITE
        // Keep the casting-only build unconstrained for new installs while
        // preserving any setting carried over from an existing installation.
        if UserDefaults.standard.object(forKey: Self.playbackRateLimitMbpsKey) == nil {
            UserDefaults.standard.set(0, forKey: Self.playbackRateLimitMbpsKey)
        }
        if UserDefaults.standard.object(forKey: Self.playbackCacheLimitMBKey) == nil {
            UserDefaults.standard.set(128, forKey: Self.playbackCacheLimitMBKey)
        }
        #endif

        let savedRateLimit = UserDefaults.standard.integer(forKey: Self.playbackRateLimitMbpsKey)
        self.playbackRateLimitMbps = [0, 5, 10, 20, 50].contains(savedRateLimit) ? savedRateLimit : 0
        let savedCacheLimit = UserDefaults.standard.integer(forKey: Self.playbackCacheLimitMBKey)
        self.playbackCacheLimitMB = [32, 64, 128, 256, 512].contains(savedCacheLimit) ? savedCacheLimit : 128

        let savedRewind = UserDefaults.standard.object(forKey: Self.rewindOnResumeSecondsKey) as? Double ?? 3.0
        self.rewindOnResumeSeconds = savedRewind
        self.skipIntroSeconds = UserDefaults.standard.double(forKey: Self.skipIntroSecondsKey)
        self.skipOutroSeconds = UserDefaults.standard.double(forKey: Self.skipOutroSecondsKey)
        self.isVoiceBoostEnabled = UserDefaults.standard.bool(forKey: Self.voiceBoostKey)
        let savedVolBoost = UserDefaults.standard.float(forKey: Self.volumeBoostKey)
        self.volumeBoost = savedVolBoost >= 1.0 && savedVolBoost <= 2.0 ? savedVolBoost : 1.0

        let avEngine = AVPlayerEngine()
        self.nativeEngine = avEngine
        self.mpvEngine = nil
        self.engine = avEngine
        self.player = avEngine.player
        applyEnginePreferences(to: self.engine)

        self.isCarPlayConnected = CarPlaySceneDelegate.shared?.isConnected ?? false
        avEngine.player.publisher(for: \.isExternalPlaybackActive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.isExternalPlaybackActive = active
            }
            .store(in: &cancellables)

        setupAudioSession()
        setupRemoteCommands()
        setupNotifications()
        observeEngineEvents()
        startTelemetryLoop()
    }

    private func applyEnginePreferences(to targetEngine: PlayerEngine) {
        targetEngine.updateSubtitlePresentation(
            isPortrait: isPortraitOrientation,
            userScale: subtitleUserScale,
            autoPortraitScale: subtitleAutoPortraitScale
        )
        targetEngine.updatePlaybackResourceLimits(
            maximumBitrate: playbackMaximumBitrate,
            cacheLimitBytes: playbackCacheLimitBytes
        )
        targetEngine.setSubtitleDelay(subtitleDelay)
        targetEngine.setSubtitleVerticalPosition(subtitleVerticalOffset)
        targetEngine.setVoiceBoost(isVoiceBoostEnabled)
        targetEngine.setVolumeBoost(volumeBoost)
        targetEngine.setSecondarySubtitleTrack(secondarySubtitleTrack)
    }

    /// The active MPV adapter is exposed only for the MPV surface view. All
    /// playback commands continue to flow through PlayerService.
    public var activeMPVEngine: MPVPlayerEngine? {
        engine as? MPVPlayerEngine
    }

    public var activeMPVRenderDiagnostic: String? {
        activeMPVEngine?.latestRenderDiagnostic()
    }

    // MARK: - Audio Session

    private func setupAudioSession() {
        Task.detached(priority: .userInitiated) {
            do {
                let audioSession = AVAudioSession.sharedInstance()
                // moviePlayback mode handles AirPlay and Bluetooth routing automatically.
                // Passing explicit options with moviePlayback triggers OSStatus error -50 (kAudio_ParamError).
                try audioSession.setCategory(.playback, mode: .moviePlayback)
                try audioSession.setActive(true)
                logger.info("AVAudioSession configured for background video playback.")
            } catch {
                logger.error("Failed to configure AVAudioSession: \(error.localizedDescription)")
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                try? AVAudioSession.sharedInstance().setActive(true)
            }
        }
    }

    private func deactivateAudioSession() {
        Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - Playback Control

    /// Routes external-display paths through AVPlayer until their MPV compatibility
    /// has been proven on device (currently AirPlay, PiP and CarPlay).
    public func loadAndPlay(
        item: MediaItem,
        origin: String = #function,
        recordHistory: Bool = true,
        requiresNativePlayback: Bool = false
    ) {
        finishCastDiagnosticSummary(reason: "replaced")
        setupAudioSession()
        if origin != "playbackFallback" {
            mpvFallbackAttempted = false
            transcodeFallbackAttempted = false
        }
        mpvInitialLoadRetryAttempted = false
        self.requiresNativePlayback = requiresNativePlayback || isCarPlayConnected
        subtitleTracks = item.subtitleTracks ?? []
        let subtitleKey = subtitlePreferenceKey(for: item)
        let savedSubtitleID = UserDefaults.standard.string(forKey: subtitleKey)
        // An empty value represents an explicit user choice to keep subtitles
        // off; a missing value still follows the server's default track.
        selectedSubtitleTrack = savedSubtitleID == ""
            ? nil
            : subtitleTracks.first { $0.id == savedSubtitleID } ?? subtitleTracks.first(where: \.isDefault)
        selectEngine(for: item, requiresNativePlayback: requiresNativePlayback)
        if let mpvEngine = engine as? MPVPlayerEngine {
            _ = mpvEngine.prepareSurfaceForLoading()
        }
        if item.sourceType == .dlna {
            castTraceGeneration += 1
            castLoadStartedAt = Date()
            castFirstFrameAt = nil
            castPlaybackStartedAt = nil
            castBufferWaitStartedAt = nil
            castTotalBufferWait = 0
            castBufferWaitCount = 0
            lastCastMetricSampleAt = .distantPast
            SSDPService.shared.recordCastDebug("ROUTE engine=\(engineName) g=\(castTraceGeneration)")
            SSDPService.shared.recordCastDebug("LOAD g=\(castTraceGeneration) origin=\(origin) sameURL=\(session.currentItem?.url == item.url) previous=\(traceTime(player.currentTime().seconds)) host=\(item.url.host ?? "local")")
        }
        firstSOAPSeekPending = item.sourceType == .dlna
        lastTracePlayerTime = nil
        lastTraceSnapshotAt = 0
        logger.info("Loading media item: \(item.title) (\(item.url.absoluteString))")
        SSDPService.shared.recordPlaybackDebug(
            "LOAD origin=\(origin) source=\(item.sourceType.rawValue) engine=\(engineName) container=\(item.playbackRequest.containerHint ?? "unknown") codec=\(item.playbackRequest.videoCodecHint ?? "unknown") alternatives=\(item.playbackAlternatives?.count ?? 0) url=\(SSDPService.sanitizedPlaybackURL(item.url))"
        )

        // Update session
        session.currentItem = item
        lastProgressReportDate = .distantPast
        lastHistoryUpdateDate = .distantPast
        session.status = .loading
        lastPauseTimestamp = nil
        hasSkippedIntroForCurrentItem = false
        showSkipOutroPrompt = false
        clearABRepeat()

        let resumePosition = max(0, item.resumePosition ?? 0)
        let effectiveStartPosition: TimeInterval
        if skipIntroSeconds > 0 && resumePosition < 5.0 {
            effectiveStartPosition = skipIntroSeconds
            hasSkippedIntroForCurrentItem = true
        } else {
            effectiveStartPosition = resumePosition
        }

        session.currentTime = effectiveStartPosition
        session.duration = item.duration ?? 0
        session.bufferedTime = 0
        session.errorMessage = nil
        if isCarPlayConnected {
            // The phone becomes the control surface while the CarPlay scene
            // owns video presentation.
            isShowingPlayer = true
        }
        NetworkSpeedMonitor.reset()
        startTelemetryLoop()

        // The AVFoundation lifecycle and item observers now live behind the engine seam.
        traceCast("REPLACE_ITEM")
        engine.setPlaybackRate(selectedSpeed)
        var request = item.playbackRequest
        if effectiveStartPosition > 0 {
            request = PlaybackRequest(
                url: request.url,
                headers: request.headers,
                startPosition: effectiveStartPosition,
                containerHint: request.containerHint,
                videoCodecHint: request.videoCodecHint,
                subtitleTracks: request.subtitleTracks
            )
        }
        engine.load(request)
        engine.setSubtitleTrack(selectedSubtitleTrack)

        // Record into history
        if recordHistory {
            PlaybackHistory.shared.addOrUpdate(item: item)
        }
        updateNowPlayingInfo()
    }

    public func play() {
        guard session.currentItem != nil else { return }
        traceCast("PLAY")
        if let pauseTime = lastPauseTimestamp, Date().timeIntervalSince(pauseTime) >= 5.0, rewindOnResumeSeconds > 0 {
            let target = max(0, session.currentTime - rewindOnResumeSeconds)
            seek(to: target)
        }
        lastPauseTimestamp = nil
        engine.setPlaybackRate(selectedSpeed)
        engine.play()
        session.status = .playing
        updateNowPlayingInfo()
    }

    public func pause() {
        traceCast("PAUSE")
        lastPauseTimestamp = Date()
        updateHistoryProgress(force: true)
        engine.pause()
        session.status = .paused
        updateNowPlayingInfo()
        reportPlaybackProgress(force: true, isPaused: true, isStopped: false)
    }

    /// Some cast senders emit a DLNA Pause as the phone locks, even though the
    /// receiver remains visible on CarPlay. Keep that one lock-triggered command
    /// from interrupting the external playback; normal foreground Pause commands
    /// still take effect.
    public func pauseFromCastController() {
        guard suppressLockedScreenCastPause else {
            pause()
            return
        }
        suppressLockedScreenCastPause = false
        traceCast("PAUSE_IGNORED phone_locked")
        SSDPService.shared.recordCastDebug("SOAP Pause ignored because phone lock preserved active CarPlay cast")
    }

    public func stop() {
        traceCast("STOP / REMOVE_ITEM")
        finishCastDiagnosticSummary(reason: "stopped")
        updateHistoryProgress(force: true)
        firstSOAPSeekPending = false
        castPlaybackStartedAt = nil
        reportPlaybackProgress(force: true, isPaused: true, isStopped: true)
        engine.stop()
        session.currentItem = nil
        session.status = .stopped
        session.currentTime = 0
        session.duration = 0
        session.bufferedTime = 0
        audioTracks = []
        selectedAudioTrack = nil
        subtitleTracks = []
        selectedSubtitleTrack = nil
        secondarySubtitleTrack = nil
        chapters = []
        clearABRepeat()
        showSkipOutroPrompt = false
        isShowingPlayer = false
        lastPauseTimestamp = nil
        stopTelemetryLoop()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        deactivateAudioSession()
    }

    public func togglePlayPause() {
        if session.status == .playing {
            pause()
        } else {
            play()
        }
    }

    /// MPV has no accepted AirPlay/PiP/CarPlay compatibility result yet. When
    /// an external presentation route is requested, restart through AVPlayer
    /// at the current position instead of exposing an untested MPV surface.
    public func requireNativePlaybackForExternalPresentation(origin: String) {
        guard engine is MPVPlayerEngine, let item = session.currentItem else { return }
        SSDPService.shared.recordPlaybackDebug(
            "EXTERNAL_PRESENTATION native_required origin=\(origin) position=\(traceTime(session.currentTime))"
        )
        loadAndPlay(
            item: item,
            origin: origin,
            recordHistory: false,
            requiresNativePlayback: true
        )
    }

    public func seek(to seconds: TimeInterval, origin: String = #function) {
        let targetSeconds = max(0, min(seconds, session.duration > 0 ? session.duration : seconds))
        if origin != "SOAP.Seek" {
            firstSOAPSeekPending = false
        }
        if origin == "SOAP.Seek", firstSOAPSeekPending {
            firstSOAPSeekPending = false
            let position = player.currentTime().seconds
            if targetSeconds == 0,
               session.status == .playing,
               position.isFinite, (0...2.5).contains(position),
               let startedAt = castPlaybackStartedAt,
               (0...3).contains(Date().timeIntervalSince(startedAt)) {
                traceCast("SKIP_INITIAL_ZERO_SEEK origin=\(origin) target=0")
                return
            }
        }
        traceCast("SEEK origin=\(origin) target=\(traceTime(targetSeconds))")
        pendingSeekOrigin = (targetSeconds, origin)
        if targetSeconds > session.bufferedTime || targetSeconds < session.currentTime {
            session.bufferedTime = targetSeconds
        }
        engine.seek(to: targetSeconds)
    }

    public func seek(by deltaSeconds: TimeInterval, origin: String = #function) {
        let target = session.currentTime + deltaSeconds
        seek(to: target, origin: origin)
    }

    public func setRate(_ rate: Float) {
        self.selectedSpeed = rate
        session.playbackRate = rate
        engine.setPlaybackRate(rate)
    }

    public func setPlaybackRateTemporary(_ rate: Float) {
        engine.setPlaybackRate(rate)
    }

    public func restorePlaybackRate() {
        engine.setPlaybackRate(selectedSpeed)
    }

    public func setAudioTrack(_ track: AudioTrack?) {
        selectedAudioTrack = track
        engine.setAudioTrack(track)
    }

    public func setSubtitleDelay(_ delay: Double) {
        let clamped = max(-30.0, min(30.0, delay))
        subtitleDelay = clamped
        UserDefaults.standard.set(clamped, forKey: Self.subtitleDelayKey)
        engine.setSubtitleDelay(clamped)
    }

    public func setSubtitleVerticalOffset(_ pos: Int) {
        let clamped = max(50, min(100, pos))
        subtitleVerticalOffset = clamped
        UserDefaults.standard.set(clamped, forKey: Self.subtitleVerticalOffsetKey)
        engine.setSubtitleVerticalPosition(clamped)
    }

    public func setSecondarySubtitleTrack(_ track: SubtitleTrack?) {
        secondarySubtitleTrack = track
        engine.setSecondarySubtitleTrack(track)
    }

    public func setRewindOnResumeSeconds(_ seconds: Double) {
        rewindOnResumeSeconds = seconds
        UserDefaults.standard.set(seconds, forKey: Self.rewindOnResumeSecondsKey)
    }

    public func setSkipIntroSeconds(_ seconds: Double) {
        skipIntroSeconds = max(0, seconds)
        UserDefaults.standard.set(skipIntroSeconds, forKey: Self.skipIntroSecondsKey)
    }

    public func setSkipOutroSeconds(_ seconds: Double) {
        skipOutroSeconds = max(0, seconds)
        UserDefaults.standard.set(skipOutroSeconds, forKey: Self.skipOutroSecondsKey)
    }

    public func setVoiceBoost(_ enabled: Bool) {
        isVoiceBoostEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.voiceBoostKey)
        engine.setVoiceBoost(enabled)
    }

    public func setVolumeBoost(_ boost: Float) {
        let clamped = max(1.0, min(2.0, boost))
        volumeBoost = clamped
        UserDefaults.standard.set(clamped, forKey: Self.volumeBoostKey)
        engine.setVolumeBoost(clamped)
    }

    public func setAudioOnlyMode(_ enabled: Bool) {
        isAudioOnlyMode = enabled
    }

    // AB Repeat
    public func setRepeatPointA() {
        repeatPointA = session.currentTime
        if let b = repeatPointB, b <= session.currentTime {
            repeatPointB = nil
            isABRepeatActive = false
        }
    }

    public func setRepeatPointB() {
        guard let a = repeatPointA, session.currentTime > a else { return }
        repeatPointB = session.currentTime
        isABRepeatActive = true
    }

    public func clearABRepeat() {
        repeatPointA = nil
        repeatPointB = nil
        isABRepeatActive = false
    }

    // Step Frame
    public func stepFrame(forward: Bool) {
        if session.status == .playing {
            pause()
        }
        engine.stepFrame(forward: forward)
        if engine === nativeEngine {
            player.currentItem?.step(byCount: forward ? 1 : -1)
        }
    }

    public func takeSnapshot(toFile path: String, includeSubtitles: Bool = false) -> Bool {
        engine.takeSnapshot(toFile: path, includeSubtitles: includeSubtitles)
    }

    public var hasNextInPlaylist: Bool {
        guard let currentItem = session.currentItem,
              let index = currentPlaylist.firstIndex(where: { $0.id == currentItem.id }),
              index + 1 < currentPlaylist.count else { return false }
        return true
    }

    public var hasPreviousInPlaylist: Bool {
        guard let currentItem = session.currentItem,
              let index = currentPlaylist.firstIndex(where: { $0.id == currentItem.id }),
              index > 0 else { return false }
        return true
    }

    public func setPlaylist(_ items: [MediaItem]) {
        self.currentPlaylist = items
    }

    public func playNextInPlaylist() {
        guard let currentItem = session.currentItem,
              let index = currentPlaylist.firstIndex(where: { $0.id == currentItem.id }),
              index + 1 < currentPlaylist.count else { return }
        let nextItem = currentPlaylist[index + 1]
        loadAndPlay(item: nextItem)
    }

    public func playPreviousInPlaylist() {
        guard let currentItem = session.currentItem,
              let index = currentPlaylist.firstIndex(where: { $0.id == currentItem.id }),
              index > 0 else { return }
        let prevItem = currentPlaylist[index - 1]
        loadAndPlay(item: prevItem)
    }

    public func toggleVideoGravity() {
        if videoGravity == .resizeAspect {
            videoGravity = .resizeAspectFill
        } else {
            videoGravity = .resizeAspect
        }
        player.externalPlaybackVideoGravity = videoGravity
    }

    public func setVolume(_ volume: Float) {
        let clamped = max(0.0, min(volume, 1.0))
        engine.setVolume(clamped)
        session.volume = clamped
    }

    public func setMuted(_ isMuted: Bool) {
        engine.setMuted(isMuted)
        session.isMuted = isMuted
    }

    public func setSubtitleTrack(_ track: SubtitleTrack?, persistPreference: Bool = true) {
        let previousID = selectedSubtitleTrack?.id ?? "off"
        let nextID = track?.id ?? "off"
        SSDPService.shared.recordPlaybackDebug(
            "[DEBUG-subtitle] REQUEST engine=\(engineName) from=\(previousID) to=\(nextID) external=\(track?.isEmbedded == false) position=\(traceTime(session.currentTime))"
        )
        if let track, !track.isEmbedded, engine === nativeEngine {
            // Do not broaden MPV routing merely to attach an external subtitle.
            // AVPlayer is retained for this native route until the complete
            // authenticated external-subtitle flow is verified on device.
            SSDPService.shared.recordPlaybackDebug(
                "[DEBUG-subtitle] NATIVE_ROUTE_RETAINED external_id=\(track.id)"
            )
        }
        selectedSubtitleTrack = track
        engine.setSubtitleTrack(track)
        SSDPService.shared.recordPlaybackDebug("[DEBUG-subtitle] APPLIED engine=\(engineName) id=\(nextID)")
        if persistPreference, let item = session.currentItem {
            let key = subtitlePreferenceKey(for: item)
            if let track { UserDefaults.standard.set(track.id, forKey: key) }
            else { UserDefaults.standard.set("", forKey: key) }
        }
    }

    public func setSubtitleUserScale(_ scale: Double) {
        let clamped = max(0.5, min(2.5, scale))
        subtitleUserScale = clamped
        UserDefaults.standard.set(clamped, forKey: Self.subtitleUserScaleKey)
        engine.updateSubtitlePresentation(
            isPortrait: isPortraitOrientation,
            userScale: clamped,
            autoPortraitScale: subtitleAutoPortraitScale
        )
    }

    public func setSubtitleAutoPortraitScale(_ enabled: Bool) {
        subtitleAutoPortraitScale = enabled
        UserDefaults.standard.set(enabled, forKey: Self.subtitleAutoPortraitKey)
        engine.updateSubtitlePresentation(
            isPortrait: isPortraitOrientation,
            userScale: subtitleUserScale,
            autoPortraitScale: enabled
        )
    }

    public func updateSubtitlePresentation(isPortrait: Bool) {
        isPortraitOrientation = isPortrait
        engine.updateSubtitlePresentation(
            isPortrait: isPortrait,
            userScale: subtitleUserScale,
            autoPortraitScale: subtitleAutoPortraitScale
        )
    }

    public func setPlaybackRateLimitMbps(_ megabitsPerSecond: Int) {
        let value = [0, 5, 10, 20, 50].contains(megabitsPerSecond) ? megabitsPerSecond : 0
        playbackRateLimitMbps = value
        UserDefaults.standard.set(value, forKey: Self.playbackRateLimitMbpsKey)
        applyPlaybackResourceLimits()
    }

    public func setPlaybackCacheLimitMB(_ megabytes: Int) {
        let value = [32, 64, 128, 256, 512].contains(megabytes) ? megabytes : 128
        playbackCacheLimitMB = value
        UserDefaults.standard.set(value, forKey: Self.playbackCacheLimitMBKey)
        applyPlaybackResourceLimits()
    }

    private var playbackMaximumBitrate: Double? {
        playbackRateLimitMbps > 0 ? Double(playbackRateLimitMbps) * 1_000_000 : nil
    }

    private var playbackCacheLimitBytes: Int64 {
        Int64(playbackCacheLimitMB) * 1024 * 1024
    }

    private func applyPlaybackResourceLimits() {
        engine.updatePlaybackResourceLimits(
            maximumBitrate: playbackMaximumBitrate,
            cacheLimitBytes: playbackCacheLimitBytes
        )
    }

    private func subtitlePreferenceKey(for item: MediaItem) -> String {
        "mivu.subtitle.\(item.serverID?.uuidString ?? "local").\(item.serverItemID ?? item.id.uuidString)"
    }

    // MARK: - Observers & Handlers

    private func observeEngineEvents() {
        engineTask?.cancel()
        let engine = self.engine
        engineGeneration += 1
        let generation = engineGeneration
        engineTask = Task { @MainActor [weak self] in
            for await event in engine.events {
                guard let self, !Task.isCancelled, self.engineGeneration == generation else { return }
                self.handleEngineEvent(event)
            }
        }
    }

    private func selectEngine(for item: MediaItem, requiresNativePlayback: Bool = false) {
        let requestedMPVEngine = requiresNativePlayback ? nil : makeMPVIfNeeded(for: item.playbackRequest)
        let route: PlaybackRoute = requiresNativePlayback
            ? .native
            : PlaybackRouter.route(
                for: item.playbackRequest,
                mpvAvailable: requestedMPVEngine?.isOperational == true
            )
        let selected: PlayerEngine
        switch route {
        case .native:
            selected = nativeEngine
        case .mpv:
            guard let mpvEngine else {
                selected = nativeEngine
                break
            }
            selected = mpvEngine
        }

        guard engine !== selected else { return }
        engineGeneration += 1
        engineTask?.cancel()
        engine.stop()
        engine = selected
        applyEnginePreferences(to: selected)
        renderSurfaceKind = selected.renderSurfaceKind
        observeEngineEvents()
    }

    private func handleEngineEvent(_ event: PlaybackEngineEvent) {
        switch event {
        case .snapshot(let snapshot):
            // A transient initial MPV HTTPS failure is retried once. Keep the
            // session in its loading state so the UI never flashes an error
            // overlay for a retry that has not actually failed yet.
            if snapshot.status == .failed, retryInitialMPVLoadIfEligible() {
                return
            }
            if session.currentItem?.sourceType == .dlna {
                let current = snapshot.currentTime
                if let previous = lastTracePlayerTime, current < previous - 0.5 {
                    traceCast("TIME_BACKWARD \(traceTime(previous))->\(traceTime(current))")
                }
                lastTracePlayerTime = current
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastTraceSnapshotAt >= 1 {
                    lastTraceSnapshotAt = now
                    traceCast("TICK sampled=\(traceTime(current))")
                }
                recordCastMetricSample(snapshot: snapshot)
            }

            let previousStatus = session.status
            let statusChanged = previousStatus != snapshot.status
            var nextSession = session
            nextSession.status = snapshot.status
            nextSession.currentTime = max(0, snapshot.currentTime)
            if snapshot.duration > 0 {
                nextSession.duration = snapshot.duration
            }
            if snapshot.bufferedTime > 0 {
                nextSession.bufferedTime = snapshot.bufferedTime
            }
            nextSession.playbackRate = snapshot.playbackRate
            nextSession.isMuted = snapshot.isMuted
            nextSession.volume = snapshot.volume
            nextSession.errorMessage = snapshot.errorMessage
            if nextSession != session {
                session = nextSession
            }
            if !snapshot.audioTracks.isEmpty || !self.audioTracks.isEmpty {
                self.audioTracks = snapshot.audioTracks
                self.selectedAudioTrack = snapshot.audioTracks.first { $0.id == snapshot.selectedAudioTrackID }
            }
            if !snapshot.chapters.isEmpty || !self.chapters.isEmpty {
                self.chapters = snapshot.chapters
            }
            updateHistoryProgress(force: false)
            pollTelemetryTick()
            if snapshot.status == .playing {
                reportPlaybackProgress(force: false, isPaused: false, isStopped: false)
            }
            if statusChanged {
                SSDPService.shared.recordPlaybackDebug(
                    "STATE engine=\(engineName) from=\(previousStatus.rawValue) to=\(snapshot.status.rawValue) position=\(traceTime(snapshot.currentTime)) duration=\(traceTime(snapshot.duration)) error=\(snapshot.errorMessage ?? "none")"
                )
                updateNowPlayingInfo()
            }
            if snapshot.status == .failed {
                handlePlaybackFailure()
            }

        case .ended:
            traceCast("DID_END currentItem=\(player.currentItem != nil)")
            finishCastDiagnosticSummary(reason: "ended")
            logger.info("Reached end of media playback.")
            session.status = .stopped
            reportPlaybackProgress(force: true, isPaused: true, isStopped: true)
            updateNowPlayingInfo()
            deactivateAudioSession()

        case .diagnostic(let diagnostic):
            switch diagnostic {
            case .itemStatus(let rawValue, let duration, let errorMessage):
                traceCast("ITEM_STATUS=\(rawValue) currentItem=\(player.currentItem != nil) duration=\(traceTime(duration))")
                SSDPService.shared.recordPlaybackDebug("ITEM_STATUS engine=\(engineName) raw=\(rawValue) duration=\(traceTime(duration)) error=\(errorMessage ?? "none")")
                if rawValue == AVPlayerItem.Status.readyToPlay.rawValue {
                    logger.info("Media ready to play. Duration: \(duration)s")
                    if session.currentItem?.sourceType == .dlna {
                        SSDPService.shared.recordPlaybackStage("媒体已就绪", successful: true)
                    }
                } else if rawValue == AVPlayerItem.Status.failed.rawValue {
                    if session.currentItem?.sourceType == .dlna {
                        SSDPService.shared.recordPlaybackStage("媒体加载失败：\(errorMessage ?? "Unknown playback error")")
                    }
                }
            case .timeControl(let rawValue, let waitingReason):
                let waiting = rawValue == AVPlayer.TimeControlStatus.waitingToPlayAtSpecifiedRate.rawValue
                updateCastBufferWait(waiting: waiting)
                if rawValue == AVPlayer.TimeControlStatus.playing.rawValue,
                   session.currentItem?.sourceType == .dlna,
                   castPlaybackStartedAt == nil {
                    castPlaybackStartedAt = Date()
                    if let started = castLoadStartedAt {
                        traceCast("CAST_START elapsed=\(traceTime(Date().timeIntervalSince(started)))")
                    }
                }
                traceCast("TIME_CONTROL=\(rawValue) waiting=\(waitingReason ?? "none")")
                SSDPService.shared.recordPlaybackDebug("TIME_CONTROL engine=\(engineName) raw=\(rawValue) waiting=\(waitingReason ?? "none")")
            case .timeJump:
                traceCast("TIME_JUMP previousSample=\(traceTime(lastTracePlayerTime ?? .nan))")
            case .streamError(let domain, let code):
                traceCast("STREAM_ERROR domain=\(domain) code=\(code)")
                SSDPService.shared.recordPlaybackDebug("STREAM_ERROR engine=\(engineName) domain=\(domain) code=\(code)")
            case .seekCompleted(let target, let finished):
                if let pending = pendingSeekOrigin, abs(pending.target - target) < 0.01 {
                    traceCast("SEEK_COMPLETED origin=\(pending.origin) target=\(traceTime(target)) finished=\(finished)")
                    if finished {
                        updateNowPlayingInfo()
                    }
                    pendingSeekOrigin = nil
                }
            case .failedToPlayToEnd(let message, let domain, let code):
                traceCast("FAILED_TO_END domain=\(domain) code=\(code)")
                session.status = .failed
                session.errorMessage = message
                finishCastDiagnosticSummary(reason: "failed_to_end")
                logger.error("Player item failed to play to end: \(message)")
            case .renderFailure(let message):
                guard engine is MPVPlayerEngine else { return }
                traceCast("RENDER_FAILURE message=\(message)")
                session.status = .failed
                session.errorMessage = message
                finishCastDiagnosticSummary(reason: "render_failed")
                logger.error("MPV render failed: \(message)")
            case .presentationSize(let width, let height):
                if width > 0, height > 0, castFirstFrameAt == nil,
                   session.currentItem?.sourceType == .dlna {
                    castFirstFrameAt = Date()
                    if let started = castLoadStartedAt {
                        traceCast("CAST_FIRST_FRAME elapsed=\(traceTime(castFirstFrameAt!.timeIntervalSince(started))) size=\(Int(width))x\(Int(height))")
                    }
                }
                SSDPService.shared.recordPlaybackDebug("VIDEO_PRESENTATION engine=\(engineName) width=\(Int(width)) height=\(Int(height))")
            }
        }
    }

    /// MPV is retained as a compatibility fallback, but its native handle and
    /// renderer are expensive enough that they should not be created for the
    /// normal AVPlayer route.
    private func makeMPVIfNeeded(for request: PlaybackRequest) -> MPVPlayerEngine? {
        guard PlaybackRouter.route(for: request, mpvAvailable: true) == .mpv else {
            return nil
        }
        if let mpvEngine { return mpvEngine.isOperational ? mpvEngine : nil }

        let candidate = MPVPlayerEngine()
        guard candidate.isOperational else { return nil }
        mpvEngine = candidate
        return candidate
    }

    private func handlePlaybackFailure() {
        if retryInitialMPVLoadIfEligible() {
            return
        }
        let hasServerAlternative = session.currentItem?.playbackAlternatives?.isEmpty == false
        if engine is MPVPlayerEngine, !mpvFallbackAttempted, !hasServerAlternative {
            // Skip the AVPlayer fallback for containers that AVPlayer definitely
            // cannot decode (WebM, MKV, etc.). Falling back would just produce a
            // second silent failure and hide the original MPV error from the user.
            let container = session.currentItem?.playbackRequest.containerHint ?? ""
            let nativeUnsupported: Set<String> = ["webm", "mkv", "avi", "flv", "ogv"]
            if nativeUnsupported.contains(container) {
                SSDPService.shared.recordPlaybackDebug("FALLBACK skipped_native_unsupported container=\(container) engine=\(engineName) error=\(session.errorMessage ?? "unknown")")
                finishCastDiagnosticSummary(reason: "failed")
            } else {
                fallbackToNativeAfterMPVFailure()
            }
            return
        }
        #if MIVU_PRO
        if engine is AVPlayerEngine,
           !mpvFallbackAttempted,
           !hasServerAlternative,
           session.currentItem?.url.scheme?.lowercased() == "mivu-smb",
           let item = session.currentItem,
           SMBLocalHTTPProxy.shared.url(for: item.url) != nil {
            if makeMPVIfNeeded(for: item.playbackRequest) != nil {
                fallbackToMPVAfterNativeSMBFailure()
                return
            }
        }
        #endif

        guard hasServerAlternative else {
            SSDPService.shared.recordPlaybackDebug("FALLBACK exhausted engine=\(engineName) error=\(session.errorMessage ?? "unknown")")
            finishCastDiagnosticSummary(reason: "failed")
            return
        }

        let failureReason = engine.snapshot.failureReason ?? .unclassified(session.errorMessage ?? "unknown")

        // 仅对确认的容器/解码失败请求转码，避免把认证、网络或服务端错误误判为需要转码
        guard failureReason.isEligibleForTranscodeFallback else {
            logger.error("Playback failed with non-decoding error (\(failureReason.categoryName)); skipping candidate fallback.")
            SSDPService.shared.recordPlaybackDebug("FALLBACK blocked_by_classification reason=\(failureReason.categoryName) engine=\(engineName) error=\(session.errorMessage ?? "unknown")")
            session.errorMessage = failureReason.userFacingMessage
            finishCastDiagnosticSummary(reason: "failed")
            return
        }

        // 一次性回退策略：单次播放仅尝试一次转码候选回退，避免死循环
        guard !transcodeFallbackAttempted else {
            logger.error("Transcode fallback already attempted; exhausting candidate fallback to avoid loop.")
            SSDPService.shared.recordPlaybackDebug("FALLBACK circuit_breaker_triggered engine=\(engineName) error=\(session.errorMessage ?? "unknown")")
            session.errorMessage = "媒体解码失败，已尝试转码仍无法播放"
            finishCastDiagnosticSummary(reason: "failed")
            return
        }

        let nextCandidateMethod = session.currentItem?.playbackAlternatives?.first?.method

        guard var nextItem = session.currentItem,
              nextItem.advanceToNextPlaybackAlternative() else {
            SSDPService.shared.recordPlaybackDebug("FALLBACK exhausted engine=\(engineName) error=\(session.errorMessage ?? "unknown")")
            finishCastDiagnosticSummary(reason: "failed")
            return
        }

        transcodeFallbackAttempted = true
        let fallbackPosition = max(session.currentTime, session.currentItem?.playbackRequest.startPosition ?? 0)
        nextItem.resumePosition = fallbackPosition

        logger.error("Playback failed with decoding error; trying the next server-provided stream: \(nextItem.url.absoluteString)")
        SSDPService.shared.recordPlaybackDebug("FALLBACK next method=\(nextCandidateMethod?.rawValue ?? "candidate") position=\(traceTime(fallbackPosition)) url=\(SSDPService.sanitizedPlaybackURL(nextItem.url)) remaining=\(nextItem.playbackAlternatives?.count ?? 0)")
        loadAndPlay(
            item: nextItem,
            origin: "playbackFallback",
            recordHistory: false,
            requiresNativePlayback: requiresNativePlayback
        )
    }

    private func fallbackToNativeAfterMPVFailure() {
        guard !mpvFallbackAttempted,
              engine is MPVPlayerEngine,
              let item = session.currentItem else { return }
        mpvFallbackAttempted = true
        logger.error("MPV playback failed; retrying the same item with AVPlayer.")
        SSDPService.shared.recordPlaybackDebug("FALLBACK mpv_to_native_same_url url=\(SSDPService.sanitizedPlaybackURL(item.url))")
        let originalRequest = item.playbackRequest
        let fallbackPosition = max(session.currentTime, originalRequest.startPosition)
        let fallbackRequest = PlaybackRequest(
            url: originalRequest.url,
            headers: originalRequest.headers,
            startPosition: fallbackPosition,
            containerHint: originalRequest.containerHint,
            videoCodecHint: originalRequest.videoCodecHint
        )

        engineGeneration += 1
        engineTask?.cancel()
        engine.stop()
        nativeEngine.stop()
        engine = nativeEngine
        renderSurfaceKind = .nativeAVPlayer
        observeEngineEvents()

        session.status = .loading
        session.currentTime = fallbackPosition
        session.duration = item.duration ?? 0
        session.bufferedTime = 0
        session.errorMessage = nil
        engine.setPlaybackRate(selectedSpeed)
        engine.load(fallbackRequest)
        updateNowPlayingInfo()
    }

    private func fallbackToMPVAfterNativeSMBFailure() {
        guard !mpvFallbackAttempted,
              engine is AVPlayerEngine,
              let item = session.currentItem,
              let mpvEngine = makeMPVIfNeeded(for: item.playbackRequest) else { return }
        mpvFallbackAttempted = true
        let request = item.playbackRequest
        let fallbackPosition = max(session.currentTime, request.startPosition)
        logger.error("AVPlayer could not decode SMB media; retrying through MPV loopback stream.")
        SSDPService.shared.recordPlaybackDebug("FALLBACK smb_native_to_mpv position=\(traceTime(fallbackPosition))")

        engineGeneration += 1
        engineTask?.cancel()
        engine.stop()
        mpvEngine.stop()
        engine = mpvEngine
        renderSurfaceKind = .mpvOpenGLES
        observeEngineEvents()

        session.status = .loading
        session.currentTime = fallbackPosition
        session.errorMessage = nil
        engine.setPlaybackRate(selectedSpeed)
        engine.load(PlaybackRequest(
            url: request.url,
            headers: request.headers,
            startPosition: fallbackPosition,
            containerHint: request.containerHint,
            videoCodecHint: request.videoCodecHint,
            subtitleTracks: request.subtitleTracks
        ))
        updateNowPlayingInfo()
    }

    private func setupNotifications() {
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.suppressLockedScreenCastPause = self.isCarPlayActive
                        && self.session.currentItem?.sourceType == .dlna
                        && self.session.status == .playing
                    if self.suppressLockedScreenCastPause {
                        self.traceCast("LOCK_GUARD armed")
                    }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.recordLifecycleDiagnostic("background")
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.recordLifecycleDiagnostic("foreground")
                    self?.suppressLockedScreenCastPause = false
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let isAirPlay = AVAudioSession.sharedInstance().currentRoute.outputs.contains {
                        $0.portType == .airPlay
                    }
                    if isAirPlay {
                        self.requireNativePlaybackForExternalPresentation(origin: "AVAudioSession.AirPlay")
                    }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleAudioInterruption(notification)
                }
            }
            .store(in: &cancellables)
    }

    private func recordLifecycleDiagnostic(_ state: String) {
        SSDPService.shared.recordPlaybackDebug(
            "LIFECYCLE state=\(state) engine=\(engineName) status=\(session.status.rawValue) position=\(traceTime(session.currentTime))"
        )
    }

    private func reportPlaybackProgress(force: Bool, isPaused: Bool, isStopped: Bool) {
        #if !MIVU_PRO
        return
        #else
        guard let item = session.currentItem,
              let itemId = item.serverItemID,
              let serverID = item.serverID else { return }
        if !force && !isStopped && Date().timeIntervalSince(lastProgressReportDate) < 15 { return }
        lastProgressReportDate = Date()
        guard let client = MediaServerManager.shared.getClient(for: serverID) else { return }
        let position = session.currentTime
        Task {
            do {
                try await client.reportPlaybackProgress(
                    itemId: itemId,
                    position: position,
                    isPaused: isPaused,
                    isStopped: isStopped,
                    playSessionId: item.playSessionID,
                    mediaSourceId: item.mediaSourceID
                )
            } catch {
                logger.debug("Playback progress report failed: \(error.localizedDescription)")
            }
        }
        #endif
    }

    private func retryInitialMPVLoadIfEligible() -> Bool {
        guard engine is MPVPlayerEngine,
              !mpvInitialLoadRetryAttempted,
              session.currentTime < 0.5,
              session.duration == 0,
              session.currentItem?.url.scheme?.lowercased() == "https",
              let item = session.currentItem else {
            return false
        }

        // FFmpeg's SecureTransport backend can transiently abort the first
        // TLS handshake. Retry once before surfacing a failure to the UI.
        mpvInitialLoadRetryAttempted = true
        session.status = .loading
        session.currentTime = max(0, item.resumePosition ?? 0)
        session.errorMessage = nil
        SSDPService.shared.recordPlaybackDebug("RETRY mpv_initial_https_load url=\(SSDPService.sanitizedPlaybackURL(item.url))")
        engine.load(item.playbackRequest)
        engine.setSubtitleTrack(selectedSubtitleTrack)
        updateNowPlayingInfo()
        return true
    }

    private func updateHistoryProgress(force: Bool) {
        guard let item = session.currentItem, session.currentTime.isFinite,
              session.currentTime > 0 else { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastHistoryUpdateDate) < 15 { return }
        lastHistoryUpdateDate = now
        PlaybackHistory.shared.updateProgress(
            for: item.id, position: session.currentTime, duration: session.duration
        )
    }

    private func traceTime(_ value: TimeInterval) -> String {
        value.isFinite ? String(format: "%.3f", value) : "unknown"
    }

    private var engineName: String {
        engine is MPVPlayerEngine ? "mpv" : "avplayer"
    }

    private func traceCast(_ event: String) {
        guard session.currentItem?.sourceType == .dlna else { return }
        SSDPService.shared.recordCastDebug("\(event) g=\(castTraceGeneration) player=\(traceTime(player.currentTime().seconds)) reported=\(traceTime(session.currentTime)) duration=\(traceTime(session.duration)) state=\(session.status.rawValue) rate=\(player.rate)")
    }

    private func updateCastBufferWait(waiting: Bool) {
        guard session.currentItem?.sourceType == .dlna else { return }
        if waiting {
            guard castBufferWaitStartedAt == nil else { return }
            castBufferWaitStartedAt = Date()
            castBufferWaitCount += 1
            traceCast("BUFFER_WAIT_BEGIN count=\(castBufferWaitCount)")
        } else if let started = castBufferWaitStartedAt {
            let duration = Date().timeIntervalSince(started)
            castTotalBufferWait += max(0, duration)
            castBufferWaitStartedAt = nil
            traceCast("BUFFER_WAIT_END duration=\(traceTime(duration)) total=\(traceTime(castTotalBufferWait))")
        }
    }

    private func recordCastMetricSample(snapshot: PlaybackEngineSnapshot) {
        guard session.currentItem?.sourceType == .dlna,
              castLoadStartedAt != nil else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCastMetricSampleAt) >= 2 else { return }
        lastCastMetricSampleAt = now
        let bufferSeconds = max(0, snapshot.bufferedTime - snapshot.currentTime)
        // DLNA can continue playing while the player cover is dismissed, so
        // sample the effective rate here instead of relying on the visible HUD
        // telemetry (which is intentionally paused in the background).
        var sampledSpeed = NetworkSpeedMonitor.currentDownloadSpeed()
        if sampledSpeed <= 0, let event = player.currentItem?.accessLog()?.events.last,
           event.observedBitrate > 0 {
            sampledSpeed = event.observedBitrate / 8.0
        }
        let bitrateBPS = max(0, Int(sampledSpeed * 8))
        SSDPService.shared.recordCastDebug(
            "METRIC bitrate_bps=\(bitrateBPS) buffer_s=\(traceTime(bufferSeconds)) engine=\(engineName)"
        )
    }

    private func finishCastDiagnosticSummary(reason: String) {
        guard let started = castLoadStartedAt,
              session.currentItem?.sourceType == .dlna else { return }
        updateCastBufferWait(waiting: false)
        let now = Date()
        let startElapsed = now.timeIntervalSince(started)
        let firstFrameElapsed = castFirstFrameAt.map { $0.timeIntervalSince(started) }
        let firstFrameText = firstFrameElapsed.map(traceTime) ?? "unknown"
        SSDPService.shared.recordCastDebug(
            "SUMMARY reason=\(reason) start_s=\(traceTime(startElapsed)) first_frame_s=\(firstFrameText) waits=\(castBufferWaitCount) wait_total_s=\(traceTime(castTotalBufferWait)) engine=\(engineName)"
        )
        castLoadStartedAt = nil
        castFirstFrameAt = nil
        castBufferWaitStartedAt = nil
    }

    // MARK: - Telemetry & Network Monitoring

    private func startTelemetryLoop() {
        telemetryTask?.cancel()
        telemetryTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let interval: UInt64 = self?.isShowingPlayer == true ? 1_000_000_000 : 2_000_000_000
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    break
                }
                guard let self = self else { return }
                self.pollTelemetryTick()
            }
        }
    }

    private func stopTelemetryLoop() {
        telemetryTask?.cancel()
        telemetryTask = nil
        downloadSpeed = 0
    }

    private func pollTelemetryTick() {
        guard session.status != .stopped && session.status != .idle && session.status != .failed else {
            if downloadSpeed != 0 {
                downloadSpeed = 0
            }
            return
        }

        // Download throughput and loaded ranges are expensive and only feed the
        // visible player HUD. Native/MPV snapshots continue to update playback
        // state and buffer position for background DLNA control.
        if isShowingPlayer {
            var speed = NetworkSpeedMonitor.currentDownloadSpeed()
            if speed <= 0, let event = player.currentItem?.accessLog()?.events.last {
                if event.observedBitrate > 0 {
                    speed = event.observedBitrate / 8.0
                }
            }
            downloadSpeed = speed

            // AVPlayerEngine already publishes loadedTimeRanges through its
            // snapshot observer; avoid a second range walk here.
        } else if downloadSpeed != 0 {
            downloadSpeed = 0
        }

        // 4. AB Repeat check
        if isABRepeatActive, let b = repeatPointB, let a = repeatPointA, session.currentTime >= b {
            seek(to: a)
        }

        // 5. Auto skip outro check
        if skipOutroSeconds > 0, session.duration > 0, hasNextInPlaylist {
            let remaining = session.duration - session.currentTime
            if remaining > 0 && remaining <= skipOutroSeconds {
                if !showSkipOutroPrompt {
                    showSkipOutroPrompt = true
                }
            } else {
                if showSkipOutroPrompt {
                    showSkipOutroPrompt = false
                }
            }
        } else if showSkipOutroPrompt {
            showSkipOutroPrompt = false
        }
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            logger.info("Audio interruption began (e.g. phone call). Pausing player.")
            pause()
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                logger.info("Audio interruption ended. Resuming playback.")
                play()
            }
        @unknown default:
            break
        }
    }

    // MARK: - Now Playing & Remote Control

    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.play()
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pause()
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.togglePlayPause()
            }
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            guard let skipEvent = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in
                self?.seek(by: skipEvent.interval, origin: "RemoteCommand.skipForward")
            }
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            guard let skipEvent = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in
                self?.seek(by: -skipEvent.interval, origin: "RemoteCommand.skipBackward")
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in
                self?.seek(to: positionEvent.positionTime, origin: "RemoteCommand.changePlaybackPosition")
            }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        if let currentItem = session.currentItem {
            info[MPMediaItemPropertyTitle] = currentItem.title
            info[MPMediaItemPropertyArtist] = currentItem.originator ?? "Mivu Receiver"
        }

        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = session.currentTime
        info[MPMediaItemPropertyPlaybackDuration] = session.duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = session.status == .playing ? Double(selectedSpeed) : 0.0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
