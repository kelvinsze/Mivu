import AVFoundation
import CoreMedia
import Foundation

@_silgen_name("mivu_mpv_create")
private func mivuMPVCreate() -> UnsafeMutableRawPointer?
@_silgen_name("mivu_mpv_destroy")
private func mivuMPVDestroy(_ player: UnsafeMutableRawPointer?)
@_silgen_name("mivu_mpv_is_initialized")
private func mivuMPVIsInitialized(_ player: UnsafeMutableRawPointer?) -> Int32
@_silgen_name("mivu_mpv_load")
private func mivuMPVLoad(_ player: UnsafeMutableRawPointer?, _ url: UnsafePointer<CChar>, _ headers: UnsafePointer<CChar>?, _ start: Double, _ startPaused: Int32) -> Int32
@_silgen_name("mivu_mpv_stop")
private func mivuMPVStop(_ player: UnsafeMutableRawPointer?) -> Int32
@_silgen_name("mivu_mpv_set_paused")
private func mivuMPVSetPaused(_ player: UnsafeMutableRawPointer?, _ paused: Int32) -> Int32
@_silgen_name("mivu_mpv_seek")
private func mivuMPVSeek(_ player: UnsafeMutableRawPointer?, _ position: Double) -> Int32
@_silgen_name("mivu_mpv_set_rate")
private func mivuMPVSetRate(_ player: UnsafeMutableRawPointer?, _ rate: Double) -> Int32
@_silgen_name("mivu_mpv_set_volume")
private func mivuMPVSetVolume(_ player: UnsafeMutableRawPointer?, _ volume: Double) -> Int32
@_silgen_name("mivu_mpv_set_muted")
private func mivuMPVSetMuted(_ player: UnsafeMutableRawPointer?, _ muted: Int32) -> Int32
@_silgen_name("mivu_mpv_poll_event")
private func mivuMPVPollEvent(_ player: UnsafeMutableRawPointer?, _ endReason: UnsafeMutablePointer<Int32>?, _ endError: UnsafeMutablePointer<Int32>?) -> Int32
@_silgen_name("mivu_mpv_snapshot")
private func mivuMPVSnapshot(_ player: UnsafeMutableRawPointer?, _ time: UnsafeMutablePointer<Double>?, _ duration: UnsafeMutablePointer<Double>?, _ buffered: UnsafeMutablePointer<Double>?, _ paused: UnsafeMutablePointer<Int32>?) -> Int32
@_silgen_name("mivu_mpv_last_error")
private func mivuMPVLastError(_ player: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?
@_silgen_name("mivu_mpv_current_hwdec")
private func mivuMPVCurrentHWDec(_ player: UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?
@_silgen_name("mivu_mpv_set_subtitle_id")
private func mivuMPVSetSubtitleID(_ player: UnsafeMutableRawPointer?, _ id: Int32) -> Int32
@_silgen_name("mivu_mpv_add_subtitle")
private func mivuMPVAddSubtitle(_ player: UnsafeMutableRawPointer?, _ url: UnsafePointer<CChar>) -> Int32

// Plan B: CoreVideo + AVSampleBufferDisplayLayer APIs
@_silgen_name("mivu_mpv_init_renderer")
private func mivuMPVInitRenderer(_ player: UnsafeMutableRawPointer?) -> Int32
@_silgen_name("mivu_mpv_render_sample_buffer")
private func mivuMPVRenderSampleBuffer(_ player: UnsafeMutableRawPointer?, _ targetWidth: Int32, _ targetHeight: Int32) -> Unmanaged<CMSampleBuffer>?
@_silgen_name("mivu_mpv_flush_renderer")
private func mivuMPVFlushRenderer(_ player: UnsafeMutableRawPointer?)
@_silgen_name("mivu_mpv_get_video_size")
private func mivuMPVGetVideoSize(_ player: UnsafeMutableRawPointer?, _ width: UnsafeMutablePointer<Int32>?, _ height: UnsafeMutablePointer<Int32>?) -> Int32
@_silgen_name("mivu_mpv_has_new_frame")
private func mivuMPVHasNewFrame(_ player: UnsafeMutableRawPointer?) -> Int32

#if canImport(MPV)
import UIKit

@MainActor
public final class MPVSampleBufferView: UIView {
    public override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    public var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    weak var engine: MPVPlayerEngine?

    public init(engine: MPVPlayerEngine) {
        self.engine = engine
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = false
        sampleBufferDisplayLayer.videoGravity = .resizeAspect
        engine.recordSurfaceDiagnostic("sample buffer view initialized")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if sampleBufferDisplayLayer.status == .failed || sampleBufferDisplayLayer.requiresFlushToResumeDecoding {
            sampleBufferDisplayLayer.flush()
        }
        sampleBufferDisplayLayer.enqueue(sampleBuffer)
    }

    public func flush() {
        sampleBufferDisplayLayer.flush()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        engine?.recordSurfaceDiagnostic("surface attached=\(window != nil)")
        if window != nil {
            engine?.onSurfaceReady()
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        if window != nil && bounds.width > 0 && bounds.height > 0 {
            engine?.surfaceViewAppeared()
        }
    }
}

public typealias MPVOpenGLESView = MPVSampleBufferView

private final class SampleBufferRendererTarget: @unchecked Sendable {
    weak var layer: AVSampleBufferDisplayLayer?

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard let layer else { return }
        if layer.status == .failed || layer.requiresFlushToResumeDecoding {
            layer.flush()
        }
        layer.enqueue(sampleBuffer)
    }

    func flush() {
        layer?.flush()
    }
}

private enum MPVControlEvent {
    case loaded(hwdec: String)
    case hardwareDecodingDiagnostic(hwdec: String)
    case ended(reason: Int32, error: Int32, message: String?)
}

private struct MPVControlUpdate {
    let events: [MPVControlEvent]
    let time: TimeInterval
    let duration: TimeInterval
    let bufferedTime: TimeInterval
    let paused: Bool
}

/// The libmpv handle is only used by the serialized control queue. The C API
/// owns the pointed-to storage, so transferring this reference does not
/// transfer mutable Swift-managed state.
private struct MPVControlHandle: @unchecked Sendable {
    let rawValue: UnsafeMutableRawPointer?

    init(_ rawValue: UnsafeMutableRawPointer?) {
        self.rawValue = rawValue
    }
}

@MainActor
public final class MPVPlayerEngine: PlayerEngine {
    public let renderSurfaceKind: PlaybackRenderSurfaceKind = .mpvSampleBuffer
    public private(set) var snapshot = PlaybackEngineSnapshot()
    public let events: AsyncStream<PlaybackEngineEvent>
    public private(set) var isOperational = false

    private var eventContinuation: AsyncStream<PlaybackEngineEvent>.Continuation?
    private var eventTask: Task<Void, Never>?
    private var handle: UnsafeMutableRawPointer?
    private let controlQueue = DispatchQueue(label: "app.mivu.mpv.control", qos: .userInitiated)
    private let renderQueue = DispatchQueue(label: "app.mivu.mpv.render", qos: .userInteractive)
    private var renderTimer: DispatchSourceTimer?
    private let sampleBufferTarget = SampleBufferRendererTarget()
    private var sampleBufferView: MPVSampleBufferView?
    private var renderFailureReported = false
    private var renderDiagnosticReported = false
    private var renderContextReady = false
    private var surfaceDiagnostic = "surface not initialized"
    private var hardwareDecodingDiagnostic = "hwdec=pending"
    private var pendingSubtitleTrack: SubtitleTrack?
    private var hasLoadedFile = false
    private var renderedFrameCount = 0
    private var webmSurfaceDiagnosticMilestones = Set<Int>()
    private var lastSurfaceAttachmentState: Bool?

    public init() {
        var continuation: AsyncStream<PlaybackEngineEvent>.Continuation?
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
        handle = mivuMPVCreate()
        isOperational = mivuMPVIsInitialized(handle) != 0
        eventTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                await self.pollEventsOnControlQueue()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    deinit {
        eventTask?.cancel()
        eventContinuation?.finish()
        renderTimer?.cancel()
        renderTimer = nil
        sampleBufferTarget.layer = nil
        if let handle {
            renderQueue.sync {
                mivuMPVDestroy(handle)
            }
        }
    }

    public func makeSampleBufferView() -> MPVSampleBufferView? {
        guard isOperational else { return nil }
        if let sampleBufferView { return sampleBufferView }
        let view = MPVSampleBufferView(engine: self)
        sampleBufferView = view
        sampleBufferTarget.layer = view.sampleBufferDisplayLayer
        return view
    }

    public func makeSurfaceView() -> MPVSampleBufferView? {
        makeSampleBufferView()
    }

    @discardableResult
    public func prepareSurfaceForLoading() -> Bool {
        guard isOperational else {
            fail("MPV framework is unavailable")
            return false
        }
        _ = makeSampleBufferView()
        let handle = MPVControlHandle(handle)
        var initResult: Int32 = -1
        renderQueue.sync {
            initResult = mivuMPVInitRenderer(handle.rawValue)
        }
        if initResult < 0 {
            fail("Unable to initialize MPV CoreVideo renderer")
            return false
        }
        renderContextReady = true
        startRenderTimer()
        return true
    }

    private func startRenderTimer() {
        guard renderTimer == nil, let handle else { return }
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        let mpvHandle = MPVControlHandle(handle)
        let target = sampleBufferTarget
        timer.setEventHandler { [weak self] in
            guard let rawHandle = mpvHandle.rawValue else { return }
            if let unmanaged = mivuMPVRenderSampleBuffer(rawHandle, 0, 0) {
                let sampleBuffer = unmanaged.takeRetainedValue()
                target.enqueue(sampleBuffer)
                Task { @MainActor [weak self] in
                    self?.onFrameRendered()
                }
            }
        }
        timer.resume()
        renderTimer = timer
    }

    private func stopRenderTimer() {
        renderTimer?.cancel()
        renderTimer = nil
    }

    fileprivate func onFrameRendered() {
        renderedFrameCount += 1
        recordSurfaceDiagnostic("frames rendered=\(renderedFrameCount)")
        if [1, 30, 90, 150].contains(renderedFrameCount) {
            recordWebMSurfaceDiagnostic("frame \(renderedFrameCount)", milestone: renderedFrameCount)
        }
        if !renderDiagnosticReported {
            renderDiagnosticReported = true
            let diag = renderDiagnostic()
            SSDPService.shared.recordPlaybackDebug("MPV_RENDER \(diag)")
        }
    }

    fileprivate func onSurfaceReady() {
        surfaceViewAppeared()
    }

    public func surfaceViewAppeared() {
        let handle = MPVControlHandle(handle)
        let target = sampleBufferTarget
        renderQueue.async { [weak self] in
            guard let rawHandle = handle.rawValue else { return }
            if let unmanaged = mivuMPVRenderSampleBuffer(rawHandle, -1, -1) {
                let sampleBuffer = unmanaged.takeRetainedValue()
                target.enqueue(sampleBuffer)
                Task { @MainActor [weak self] in
                    self?.onFrameRendered()
                }
            }
        }
    }

    public func latestRenderDiagnostic() -> String {
        "\(hardwareDecodingDiagnostic); \(surfaceDiagnostic); \(renderDiagnostic())"
    }

    fileprivate func recordSurfaceDiagnostic(_ message: String) {
        surfaceDiagnostic = message
        guard message.hasPrefix("surface attached=") else { return }
        let attached = message == "surface attached=true"
        guard lastSurfaceAttachmentState != attached else { return }
        lastSurfaceAttachmentState = attached
        recordWebMSurfaceDiagnostic("didMoveToWindow attached=\(attached)")
    }

    private func recordWebMSurfaceDiagnostic(_ reason: String, milestone: Int? = nil) {
        if let milestone, !webmSurfaceDiagnosticMilestones.insert(milestone).inserted {
            return
        }
        let view = sampleBufferView
        let layer = view?.sampleBufferDisplayLayer
        let error = layer?.error.map { error -> String in
            let nsError = error as NSError
            return "\(nsError.domain)/\(nsError.code)"
        } ?? "none"
        let bounds = view.map { "\($0.bounds.width)x\($0.bounds.height)" } ?? "none"
        let layerFrame = layer.map { "\($0.frame.width)x\($0.frame.height)" } ?? "none"
        let activationState = view?.window?.windowScene?.activationState.rawValue ?? -1
        let readyForDisplay: String
        if #available(iOS 17.4, *) {
            readyForDisplay = layer.map { String($0.isReadyForDisplay) } ?? "none"
        } else {
            readyForDisplay = "unavailable"
        }
        let videoWindow = view?.window
        let videoWindowID = videoWindow.map { String(describing: ObjectIdentifier($0)) } ?? "none"
        let sceneWindows = videoWindow?.windowScene?.windows.map { window in
            let id = String(describing: ObjectIdentifier(window))
            let root = window.rootViewController.map { String(describing: type(of: $0)) } ?? "none"
            let presented = window.rootViewController?.presentedViewController
                .map { String(describing: type(of: $0)) } ?? "none"
            return "id=\(id),key=\(window.isKeyWindow),hidden=\(window.isHidden),alpha=\(window.alpha),level=\(window.windowLevel.rawValue),video=\(window === videoWindow),root=\(root),presented=\(presented)"
        }.joined(separator: ";") ?? "none"
        var parentChain: [String] = []
        var parent: UIView? = view
        for _ in 0..<6 {
            guard let current = parent else { break }
            let id = String(describing: ObjectIdentifier(current))
            parentChain.append("\(String(describing: type(of: current)))#\(id),hidden=\(current.isHidden),alpha=\(current.alpha)")
            parent = current.superview
        }
        SSDPService.shared.recordPlaybackDebug(
            "[DEBUG-webm-surface] reason=\(reason) renderedFrameCount=\(renderedFrameCount) " +
            "view=\(view != nil) window=\(view?.window != nil) bounds=\(bounds) layerFrame=\(layerFrame) " +
            "isReadyForDisplay=\(readyForDisplay) status=\(layer?.status.rawValue ?? -1) " +
            "isReadyForMoreMediaData=\(layer?.isReadyForMoreMediaData ?? false) " +
            "requiresFlushToResumeDecoding=\(layer?.requiresFlushToResumeDecoding ?? false) " +
            "error=\(error) windowScene.activationState=\(activationState) " +
            "videoWindowID=\(videoWindowID) videoWindow.key=\(videoWindow?.isKeyWindow ?? false) " +
            "videoWindow.hidden=\(videoWindow?.isHidden ?? false) videoWindow.alpha=\(videoWindow?.alpha ?? 0) " +
            "videoWindow.level=\(videoWindow?.windowLevel.rawValue ?? 0) sceneWindows=[\(sceneWindows)] " +
            "viewParentChain=[\(parentChain.joined(separator: " <- "))]"
        )
    }

    public func load(_ request: PlaybackRequest) {
        guard isOperational else {
            fail("MPV framework is unavailable")
            return
        }
        hasLoadedFile = false
        pendingSubtitleTrack = nil
        renderFailureReported = false
        renderDiagnosticReported = false
        renderedFrameCount = 0
        webmSurfaceDiagnosticMilestones.removeAll()
        lastSurfaceAttachmentState = nil
        let startPaused: Int32 = 0
        startRenderTimer()
        updateSnapshot {
            $0.status = .loading
            $0.currentTime = request.startPosition
            $0.duration = 0
            $0.bufferedTime = 0
            $0.errorMessage = nil
        }
        // Newlines delimit complete header fields without corrupting values such
        // as X-Emby-Authorization, whose value legitimately contains commas.
        let headerString = request.headers
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        let sourceURL: URL
        if request.url.scheme?.lowercased() == "mivu-smb" {
            guard let proxyURL = SMBLocalHTTPProxy.shared.url(for: request.url) else {
                fail("SMB local stream is unavailable")
                return
            }
            sourceURL = proxyURL
        } else {
            sourceURL = request.url
        }
        let handle = MPVControlHandle(handle)
        controlQueue.async { [weak self] in
            let result = sourceURL.absoluteString.withCString { url in
                headerString.withCString { headers in
                    mivuMPVLoad(handle.rawValue, url, headerString.isEmpty ? nil : headers, request.startPosition, startPaused)
                }
            }
            guard result < 0 else { return }
            let message = Self.controlError(handle.rawValue)
            Task { @MainActor [weak self] in self?.fail(message) }
        }
    }

    public func play() {
        guard isOperational else { return }
        startRenderTimer()
        let handle = MPVControlHandle(handle)
        controlQueue.async { _ = mivuMPVSetPaused(handle.rawValue, 0) }
        updateSnapshot { $0.status = .playing; $0.errorMessage = nil }
    }

    public func pause() {
        guard isOperational else { return }
        let handle = MPVControlHandle(handle)
        controlQueue.async { _ = mivuMPVSetPaused(handle.rawValue, 1) }
        updateSnapshot { $0.status = .paused }
    }

    public func stop() {
        stopRenderTimer()
        sampleBufferTarget.flush()
        let handle = MPVControlHandle(handle)
        controlQueue.async { _ = mivuMPVStop(handle.rawValue) }
        renderQueue.async {
            mivuMPVFlushRenderer(handle.rawValue)
        }
        hasLoadedFile = false
        pendingSubtitleTrack = nil
        renderedFrameCount = 0
        updateSnapshot {
            $0.status = .stopped
            $0.currentTime = 0
            $0.duration = 0
            $0.bufferedTime = 0
            $0.errorMessage = nil
        }
    }

    public func seek(to time: TimeInterval) {
        let target = max(0, time)
        let handle = MPVControlHandle(handle)
        controlQueue.async { [weak self] in
            let result = mivuMPVSeek(handle.rawValue, target)
            Task { @MainActor [weak self] in
                self?.eventContinuation?.yield(.diagnostic(.seekCompleted(target: target, finished: result >= 0)))
            }
        }
    }

    public func setPlaybackRate(_ rate: Float) {
        let clamped = max(0.1, rate)
        let handle = MPVControlHandle(handle)
        controlQueue.async { _ = mivuMPVSetRate(handle.rawValue, Double(clamped)) }
        updateSnapshot { $0.playbackRate = clamped }
    }

    public func setVolume(_ volume: Float) {
        let clamped = max(0, min(volume, 1))
        let handle = MPVControlHandle(handle)
        controlQueue.async { _ = mivuMPVSetVolume(handle.rawValue, Double(clamped)) }
        updateSnapshot { $0.volume = clamped }
    }

    public func setMuted(_ isMuted: Bool) {
        let handle = MPVControlHandle(handle)
        controlQueue.async { _ = mivuMPVSetMuted(handle.rawValue, isMuted ? 1 : 0) }
        updateSnapshot { $0.isMuted = isMuted }
    }

    public func setSubtitleTrack(_ track: SubtitleTrack?) {
        pendingSubtitleTrack = track
        guard hasLoadedFile else {
            SSDPService.shared.recordPlaybackDebug("[DEBUG-subtitle] MPV_DEFER id=\(track?.id ?? "off")")
            return
        }
        applySubtitleTrack(track)
    }

    private func applySubtitleTrack(_ track: SubtitleTrack?) {
        let handle = MPVControlHandle(handle)
        guard let track else {
            controlQueue.async {
                let result = mivuMPVSetSubtitleID(handle.rawValue, 0)
                Task { @MainActor in
                    SSDPService.shared.recordPlaybackDebug("[DEBUG-subtitle] MPV_SID id=0 result=\(result)")
                }
            }
            return
        }
        if !track.isEmbedded, let url = track.url {
            controlQueue.async {
                let result = url.absoluteString.withCString { mivuMPVAddSubtitle(handle.rawValue, $0) }
                Task { @MainActor in
                    SSDPService.shared.recordPlaybackDebug("[DEBUG-subtitle] MPV_SUB_ADD id=\(track.id) result=\(result)")
                }
            }
        } else if let id = Int32(track.id) {
            controlQueue.async {
                let result = mivuMPVSetSubtitleID(handle.rawValue, id)
                Task { @MainActor in
                    SSDPService.shared.recordPlaybackDebug("[DEBUG-subtitle] MPV_SID id=\(id) result=\(result)")
                }
            }
        }
    }

    private func pollEventsOnControlQueue() async {
        guard isOperational else { return }
        let handle = MPVControlHandle(handle)
        let update = await withCheckedContinuation { continuation in
            controlQueue.async {
                continuation.resume(returning: Self.collectControlUpdate(handle.rawValue))
            }
        }
        applyControlUpdate(update)
    }

    nonisolated private static func collectControlUpdate(_ handle: UnsafeMutableRawPointer?) -> MPVControlUpdate {
        var events: [MPVControlEvent] = []
        var endReason: Int32 = 0
        var endError: Int32 = 0
        var event = mivuMPVPollEvent(handle, &endReason, &endError)
        while event > 0 {
            if event == 1 {
                let hwdec = mivuMPVCurrentHWDec(handle).map { String(cString: $0) } ?? "unavailable"
                events.append(.loaded(hwdec: hwdec))
            } else if event == 2 {
                let message = endError < 0 ? controlError(handle) : nil
                events.append(.ended(reason: endReason, error: endError, message: message))
            } else if event == 3 {
                let hwdec = mivuMPVCurrentHWDec(handle).map { String(cString: $0) } ?? "unavailable"
                events.append(.hardwareDecodingDiagnostic(hwdec: hwdec))
            }
            event = mivuMPVPollEvent(handle, &endReason, &endError)
        }
        var time = 0.0
        var duration = 0.0
        var buffered = 0.0
        var paused: Int32 = 1
        guard mivuMPVSnapshot(handle, &time, &duration, &buffered, &paused) >= 0 else {
            return MPVControlUpdate(events: events, time: 0, duration: 0, bufferedTime: 0, paused: true)
        }
        return MPVControlUpdate(events: events, time: time, duration: duration, bufferedTime: buffered, paused: paused != 0)
    }

    private func applyControlUpdate(_ update: MPVControlUpdate) {
        for event in update.events {
            switch event {
            case let .loaded(hwdec):
                hasLoadedFile = true
                hardwareDecodingDiagnostic = "hwdec=\(hwdec)"
                SSDPService.shared.recordPlaybackDebug("MPV_HWDEC active=\(hwdec)")
                recordWebMSurfaceDiagnostic("loaded", milestone: -1)
                applySubtitleTrack(pendingSubtitleTrack)
                updateSnapshot {
                    $0.status = .playing
                    $0.errorMessage = nil
                }
                eventContinuation?.yield(.diagnostic(.itemStatus(rawValue: 1, duration: snapshot.duration, errorMessage: nil)))
                surfaceViewAppeared()
            case let .hardwareDecodingDiagnostic(hwdec):
                hardwareDecodingDiagnostic = "hwdec=\(hwdec)"
                SSDPService.shared.recordPlaybackDebug("MPV_HWDEC reconfig=\(hwdec)")
            case let .ended(reason, error, message):
                if reason == 4 || error < 0 {
                    let errorMessage = message ?? "MPV playback ended with an error"
                    SSDPService.shared.recordPlaybackDebug("MPV_END_FILE reason=\(reason) error=\(error) message=\(errorMessage)")
                    fail(errorMessage)
                } else if !hasLoadedFile {
                    // mpv may emit END_FILE before FILE_LOADED when it cannot
                    // find a suitable decoder or demuxer. Treat this as an
                    // error so the fallback path can trigger.
                    let errorMessage = message ?? "MPV failed to load the file (reason=\(reason))"
                    SSDPService.shared.recordPlaybackDebug("MPV_END_FILE before_load reason=\(reason) error=\(error) message=\(errorMessage)")
                    fail(errorMessage)
                } else {
                    updateSnapshot { $0.status = .stopped }
                    eventContinuation?.yield(.ended)
                }
            }
        }
        updateSnapshot {
            $0.currentTime = update.time
            $0.duration = update.duration
            if update.bufferedTime > 0 {
                $0.bufferedTime = update.bufferedTime
            }
            if $0.status != .loading && $0.status != .stopped && $0.status != .failed {
                $0.status = update.paused ? .paused : .playing
            }
        }
    }

    private func updateSnapshot(_ update: (inout PlaybackEngineSnapshot) -> Void) {
        var next = snapshot
        update(&next)
        guard next != snapshot else { return }
        snapshot = next
        eventContinuation?.yield(.snapshot(next))
    }

    private func fail(_ message: String) {
        updateSnapshot {
            $0.status = .failed
            $0.errorMessage = message
        }
        eventContinuation?.yield(.diagnostic(.itemStatus(rawValue: 2, duration: snapshot.duration, errorMessage: message)))
    }

    private func reportRenderFailure() {
        guard !renderFailureReported else { return }
        renderFailureReported = true
        let message = renderDiagnostic()
        updateSnapshot {
            $0.status = .failed
            $0.errorMessage = message
        }
        eventContinuation?.yield(.diagnostic(.renderFailure(message: message)))
    }

    nonisolated private static func controlError(_ handle: UnsafeMutableRawPointer?) -> String {
        guard let pointer = mivuMPVLastError(handle) else { return "MPV playback failed" }
        return String(cString: pointer)
    }

    private func renderDiagnostic() -> String {
        guard let pointer = mivuMPVLastError(handle) else { return "MPV OpenGL ES rendering failed" }
        return String(cString: pointer)
    }
}
#else

@MainActor
public final class MPVPlayerEngine: PlayerEngine {
    public let renderSurfaceKind: PlaybackRenderSurfaceKind = .nativeAVPlayer
    public private(set) var snapshot = PlaybackEngineSnapshot()
    public let events: AsyncStream<PlaybackEngineEvent>
    public let isOperational = false

    public init() {
        events = AsyncStream { continuation in continuation.finish() }
    }

    public func load(_ request: PlaybackRequest) {}
    public func latestRenderDiagnostic() -> String { "MPV framework is unavailable" }
    public func play() {}
    public func pause() {}
    public func stop() {}
    public func seek(to time: TimeInterval) {}
    public func setPlaybackRate(_ rate: Float) {}
    public func setVolume(_ volume: Float) {}
    public func setMuted(_ isMuted: Bool) {}
    public func setSubtitleTrack(_ track: SubtitleTrack?) {}
    public func surfaceViewAppeared() {}
    @discardableResult public func prepareSurfaceForLoading() -> Bool { false }
}
#endif
