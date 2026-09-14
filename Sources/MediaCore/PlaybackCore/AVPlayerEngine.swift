import Foundation
import AVFoundation

/// Native AVPlayer adapter used during the migration to PlaybackCore.
///
/// Keeping this adapter behind `PlayerEngine` lets a future MPV adapter be
/// introduced without changing PlayerService, DLNA, CarPlay, or UI callers.
@MainActor
public final class AVPlayerEngine: PlayerEngine {
    public let player: AVPlayer
    public let renderSurfaceKind: PlaybackRenderSurfaceKind = .nativeAVPlayer
    public private(set) var snapshot = PlaybackEngineSnapshot()
    public let events: AsyncStream<PlaybackEngineEvent>

    private var eventContinuation: AsyncStream<PlaybackEngineEvent>.Continuation?
    private var timeObserverToken: Any?
    private var itemStatusObserver: NSKeyValueObservation?
    private var itemDurationObserver: NSKeyValueObservation?
    private var itemLoadedRangesObserver: NSKeyValueObservation?
    private var itemBufferEmptyObserver: NSKeyValueObservation?
    private var itemBufferKeepUpObserver: NSKeyValueObservation?
    private var itemPresentationSizeObserver: NSKeyValueObservation?
    private var playerTimeControlObserver: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var pendingSubtitleTrack: SubtitleTrack?
    private var smbResourceLoader: SMBAssetResourceLoader?
    private var maximumBitrate: Double?
    private var cacheLimitBytes: Int64 = 128 * 1024 * 1024

    public init(player: AVPlayer = AVPlayer()) {
        var continuation: AsyncStream<PlaybackEngineEvent>.Continuation?
        let eventStream = AsyncStream<PlaybackEngineEvent> { streamContinuation in
            continuation = streamContinuation
        }
        self.player = player
        self.events = eventStream
        self.eventContinuation = continuation

        player.allowsExternalPlayback = true
        player.externalPlaybackVideoGravity = .resizeAspect
        player.automaticallyWaitsToMinimizeStalling = true

        setupPeriodicTimeObserver()
        setupNotifications()
    }

    deinit {
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
        }
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        eventContinuation?.finish()
    }

    public func load(_ request: PlaybackRequest) {
        invalidateCurrentItemObservers()

        let asset: AVURLAsset
        if let resourceLoader = SMBAssetResourceLoader(url: request.url) {
            smbResourceLoader = resourceLoader
            asset = resourceLoader.makeAsset()
        } else if request.headers.isEmpty {
            smbResourceLoader = nil
            asset = AVURLAsset(url: request.url)
        } else {
            smbResourceLoader = nil
            asset = AVURLAsset(url: request.url, options: ["AVURLAssetHTTPHeaderFieldsKey": request.headers])
        }

        let playerItem = AVPlayerItem(asset: asset)
        applyResourceLimits(to: playerItem)
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        installItemObservers(for: playerItem)

        updateSnapshot {
            $0.status = .loading
            $0.currentTime = request.startPosition
            $0.duration = 0
            $0.bufferedTime = 0
            $0.errorMessage = nil
            $0.audioTracks = []
            $0.selectedAudioTrackID = nil
            $0.chapters = []
        }

        player.replaceCurrentItem(with: playerItem)
        if request.startPosition > 0 {
            player.seek(
                to: CMTime(seconds: request.startPosition, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
        player.rate = snapshot.playbackRate
        player.volume = snapshot.volume
        player.isMuted = snapshot.isMuted
        player.play()
    }

    public func play() {
        guard player.currentItem != nil else { return }
        player.rate = snapshot.playbackRate
        player.play()
        updateSnapshot { $0.status = .playing; $0.errorMessage = nil }
    }

    public func pause() {
        player.pause()
        updateSnapshot { $0.status = .paused }
    }

    public func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        smbResourceLoader = nil
        invalidateCurrentItemObservers()
        updateSnapshot {
            $0.status = .stopped
            $0.currentTime = 0
            $0.duration = 0
            $0.bufferedTime = 0
            $0.errorMessage = nil
            $0.audioTracks = []
            $0.selectedAudioTrackID = nil
            $0.chapters = []
        }
    }

    public func seek(to time: TimeInterval) {
        let target = max(0, time)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if finished {
                    self.updateSnapshot { $0.currentTime = target }
                }
                self.eventContinuation?.yield(.diagnostic(.seekCompleted(target: target, finished: finished)))
            }
        }
    }

    public func setPlaybackRate(_ rate: Float) {
        let clamped = max(0.1, rate)
        updateSnapshot { $0.playbackRate = clamped }
        if snapshot.status == .playing {
            player.rate = clamped
        }
    }

    public func setVolume(_ volume: Float) {
        let clamped = max(0, min(volume, 1))
        player.volume = clamped
        updateSnapshot { $0.volume = clamped }
    }

    public func setMuted(_ isMuted: Bool) {
        player.isMuted = isMuted
        updateSnapshot { $0.isMuted = isMuted }
    }

    public func setSubtitleTrack(_ track: SubtitleTrack?) {
        pendingSubtitleTrack = track
        guard let item = player.currentItem else { return }
        let asset = item.asset
        Task { @MainActor [weak self, weak item] in
            guard let self,
                  let item,
                  self.player.currentItem === item,
                  self.pendingSubtitleTrack == track,
                  let group = try? await asset.loadMediaSelectionGroup(for: .legible),
                  self.player.currentItem === item,
                  self.pendingSubtitleTrack == track else { return }
            self.applySubtitleTrack(track, to: item, in: group)
        }
    }

    public func setAudioTrack(_ track: AudioTrack?) {
        guard let track, let item = player.currentItem else { return }
        let asset = item.asset
        Task { @MainActor [weak self, weak item] in
            guard let self, let item, self.player.currentItem === item else { return }
            guard let group = try? await asset.loadMediaSelectionGroup(for: .audible) else { return }
            let index = Int(track.id) ?? -1
            if (0..<group.options.count).contains(index) {
                let option = group.options[index]
                item.select(option, in: group)
                self.updateSnapshot {
                    $0.selectedAudioTrackID = track.id
                }
            }
        }
    }

    public func updatePlaybackResourceLimits(maximumBitrate: Double?, cacheLimitBytes: Int64) {
        self.maximumBitrate = maximumBitrate
        self.cacheLimitBytes = max(16 * 1024 * 1024, cacheLimitBytes)
        if let item = player.currentItem {
            applyResourceLimits(to: item)
        }
    }

    private func applyResourceLimits(to item: AVPlayerItem) {
        item.preferredPeakBitRate = maximumBitrate ?? 0

        // AVFoundation exposes a duration rather than a byte-exact cache cap.
        // Convert the selected byte budget using the selected rate, or a
        // conservative 10 Mbps baseline when no rate is selected.
        let referenceBitrate = maximumBitrate ?? 10_000_000
        let seconds = Double(cacheLimitBytes) * 8 / referenceBitrate
        item.preferredForwardBufferDuration = min(max(seconds, 5), 180)
    }

    private func applySubtitleTrack(_ track: SubtitleTrack?, to item: AVPlayerItem, in group: AVMediaSelectionGroup) {
        if track == nil {
            item.select(nil, in: group)
            return
        }
        let index = Int(track!.id) ?? -1
        var selectedOption: AVMediaSelectionOption?
        for (offset, option) in group.options.enumerated() {
            if option.extendedLanguageTag == track!.language || option.displayName == track!.title {
                selectedOption = option
                break
            }
            if offset == index {
                selectedOption = option
            }
        }
        item.select(selectedOption, in: group)
    }

    private func updateSnapshot(_ update: (inout PlaybackEngineSnapshot) -> Void) {
        var next = snapshot
        update(&next)
        snapshot = next
        eventContinuation?.yield(.snapshot(next))
    }

    private func invalidateCurrentItemObservers() {
        itemStatusObserver?.invalidate()
        itemDurationObserver?.invalidate()
        itemLoadedRangesObserver?.invalidate()
        itemBufferEmptyObserver?.invalidate()
        itemBufferKeepUpObserver?.invalidate()
        itemPresentationSizeObserver?.invalidate()
        itemStatusObserver = nil
        itemDurationObserver = nil
        itemLoadedRangesObserver = nil
        itemBufferEmptyObserver = nil
        itemBufferKeepUpObserver = nil
        itemPresentationSizeObserver = nil
    }

    private func installItemObservers(for item: AVPlayerItem) {
        itemStatusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in self?.handleItemStatusChange(item) }
        }
        itemDurationObserver = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, item === self.player.currentItem else { return }
                let dur = CMTimeGetSeconds(item.duration)
                if dur.isFinite && !dur.isNaN && dur > 0 {
                    self.updateSnapshot { $0.duration = dur }
                }
            }
        }
        itemLoadedRangesObserver = item.observe(\.loadedTimeRanges, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in self?.handleLoadedTimeRangesChange(item) }
        }
        itemBufferEmptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            guard item.isPlaybackBufferEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, item === self.player.currentItem else { return }
                self.updateSnapshot { $0.status = .loading }
            }
        }
        itemBufferKeepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            guard item.isPlaybackLikelyToKeepUp else { return }
            Task { @MainActor [weak self] in
                guard let self, item === self.player.currentItem, self.snapshot.status == .loading else { return }
                self.play()
            }
        }
        itemPresentationSizeObserver = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, item === self.player.currentItem else { return }
                self.eventContinuation?.yield(.diagnostic(.presentationSize(
                    width: Double(item.presentationSize.width),
                    height: Double(item.presentationSize.height)
                )))
            }
        }
    }

    private func setupPeriodicTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let current = CMTimeGetSeconds(time)
                guard current.isFinite, !current.isNaN else { return }
                self.updateSnapshot {
                    $0.currentTime = max(0, current)
                    if $0.duration == 0, let dur = self.player.currentItem?.duration.seconds, dur.isFinite, !dur.isNaN, dur > 0 {
                        $0.duration = dur
                    }
                }
                if let currentItem = self.player.currentItem {
                    self.handleLoadedTimeRangesChange(currentItem)
                }
            }
        }

        playerTimeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch player.timeControlStatus {
                case .playing:
                    self.updateSnapshot { $0.status = .playing }
                case .paused:
                    if self.snapshot.status != .stopped && self.snapshot.status != .failed {
                        self.updateSnapshot { $0.status = .paused }
                    }
                case .waitingToPlayAtSpecifiedRate:
                    self.updateSnapshot { $0.status = .loading }
                @unknown default:
                    break
                }
                self.eventContinuation?.yield(.diagnostic(.timeControl(
                    rawValue: player.timeControlStatus.rawValue,
                    waitingReason: player.reasonForWaitingToPlay?.rawValue
                )))
            }
        }
    }

    private func setupNotifications() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: .AVPlayerItemTimeJumped, object: nil, queue: .main) { [weak self] notification in
            let notification = notification
            Task { @MainActor [weak self] in
                guard let self, let item = notification.object as? AVPlayerItem, item === self.player.currentItem else { return }
                self.eventContinuation?.yield(.diagnostic(.timeJump))
            }
        })
        notificationTokens.append(center.addObserver(forName: .AVPlayerItemNewErrorLogEntry, object: nil, queue: .main) { [weak self] notification in
            let notification = notification
            Task { @MainActor [weak self] in
                guard let self, let item = notification.object as? AVPlayerItem,
                      item === self.player.currentItem, let event = item.errorLog()?.events.last else { return }
                self.eventContinuation?.yield(.diagnostic(.streamError(domain: event.errorDomain, code: event.errorStatusCode)))
            }
        })
        notificationTokens.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            let notification = notification
            Task { @MainActor [weak self] in
                guard let self, let item = notification.object as? AVPlayerItem, item === self.player.currentItem else { return }
                self.updateSnapshot { $0.status = .stopped }
                self.eventContinuation?.yield(.ended)
            }
        })
        notificationTokens.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            let notification = notification
            Task { @MainActor [weak self] in
                guard let self, let item = notification.object as? AVPlayerItem, item === self.player.currentItem else { return }
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                let message = error?.localizedDescription ?? "Playback failed before ending."
                let nsError = error as NSError?
                self.updateSnapshot { $0.status = .failed; $0.errorMessage = message }
                self.eventContinuation?.yield(.diagnostic(.failedToPlayToEnd(
                    message: message,
                    domain: nsError?.domain ?? "unknown",
                    code: nsError?.code ?? 0
                )))
            }
        })
    }

    private func handleItemStatusChange(_ item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        let duration = CMTimeGetSeconds(item.duration)
        let safeDuration = duration.isFinite && !duration.isNaN ? max(0, duration) : 0
        switch item.status {
        case .readyToPlay:
            if let pendingSubtitleTrack { setSubtitleTrack(pendingSubtitleTrack) }
            let asset = item.asset
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else { return }
                var tracks: [AudioTrack] = []
                var selectedID: String?
                if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
                    let selectedOption = item.currentMediaSelection.selectedMediaOption(in: group)
                    for (idx, option) in group.options.enumerated() {
                        let id = "\(idx)"
                        let lang = option.extendedLanguageTag ?? option.locale?.identifier
                        let title = option.displayName
                        if option == selectedOption {
                            selectedID = id
                        }
                        tracks.append(AudioTrack(id: id, language: lang, title: title, format: option.mediaType.rawValue, isDefault: idx == 0))
                    }
                    if selectedID == nil, let first = tracks.first {
                        selectedID = first.id
                    }
                }

                var parsedChapters: [PlaybackChapter] = []
                if let chapterGroups = try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages) {
                    for (idx, group) in chapterGroups.enumerated() {
                        let start = CMTimeGetSeconds(group.timeRange.start)
                        let dur = CMTimeGetSeconds(group.timeRange.duration)
                        guard start.isFinite && !start.isNaN else { continue }
                        var name = "第 \(idx + 1) 章"
                        for metaItem in group.items {
                            if let stringVal = try? await metaItem.load(.stringValue), !stringVal.isEmpty {
                                name = stringVal
                                break
                            }
                        }
                        parsedChapters.append(PlaybackChapter(id: "\(idx)", title: name, startTime: max(0, start), duration: max(0, dur.isFinite ? dur : 0)))
                    }
                }

                self.updateSnapshot {
                    $0.audioTracks = tracks
                    $0.selectedAudioTrackID = selectedID
                    $0.chapters = parsedChapters
                }
            }
            updateSnapshot {
                $0.status = .playing
                if safeDuration > 0 {
                    $0.duration = safeDuration
                }
                $0.errorMessage = nil
            }
            handleLoadedTimeRangesChange(item)
            eventContinuation?.yield(.diagnostic(.itemStatus(rawValue: item.status.rawValue, duration: safeDuration, errorMessage: nil)))
        case .failed:
            let message = item.error?.localizedDescription ?? "Unknown playback error"
            updateSnapshot { $0.status = .failed; $0.errorMessage = message }
            eventContinuation?.yield(.diagnostic(.itemStatus(rawValue: item.status.rawValue, duration: safeDuration, errorMessage: message)))
        case .unknown:
            updateSnapshot { $0.status = .loading }
            eventContinuation?.yield(.diagnostic(.itemStatus(rawValue: item.status.rawValue, duration: safeDuration, errorMessage: nil)))
        @unknown default:
            break
        }
    }

    private func handleLoadedTimeRangesChange(_ item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        let current = snapshot.currentTime
        var maxBuffered: TimeInterval = 0
        for value in item.loadedTimeRanges {
            let timeRange = value.timeRangeValue
            let start = CMTimeGetSeconds(timeRange.start)
            let duration = CMTimeGetSeconds(timeRange.duration)
            guard start.isFinite && duration.isFinite && !start.isNaN && !duration.isNaN else { continue }
            let end = start + duration
            if start <= current + 1.5 && end >= current {
                maxBuffered = max(maxBuffered, end)
            } else if start <= 1.0 {
                maxBuffered = max(maxBuffered, end)
            }
        }
        if maxBuffered == 0 {
            for value in item.loadedTimeRanges {
                let timeRange = value.timeRangeValue
                let start = CMTimeGetSeconds(timeRange.start)
                let duration = CMTimeGetSeconds(timeRange.duration)
                if start.isFinite && duration.isFinite && !start.isNaN && !duration.isNaN {
                    maxBuffered = max(maxBuffered, start + duration)
                }
            }
        }
        guard maxBuffered > 0 else { return }
        updateSnapshot { $0.bufferedTime = maxBuffered }
    }
}
