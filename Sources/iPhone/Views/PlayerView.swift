import SwiftUI
import AVKit
import MediaPlayer
import Photos

@MainActor
private enum PlaybackOrientation {
    private static var activeWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first {
                $0.activationState == .foregroundActive
                    && $0.session.role == .windowApplication
            }
    }

    static func lockToLandscape() {
        activeWindowScene?.requestGeometryUpdate(
            .iOS(interfaceOrientations: .landscape)
        )
    }

    static func restoreAppOrientations() {
        let supportedOrientations: UIInterfaceOrientationMask = UIDevice.current.userInterfaceIdiom == .pad
            ? .all
            : .allButUpsideDown
        activeWindowScene?.requestGeometryUpdate(
            .iOS(interfaceOrientations: supportedOrientations)
        )
    }
}

/// Video Player View embedding native AVPlayer / MPV surface,
/// frosted-glass overlays, gesture brightness/volume HUD, precision scrubbing,
/// speed selector, subtitle management, aspect ratio toggle, and stream telemetry HUD.
public struct PlayerView: View {
    @ObservedObject var playerService = PlayerService.shared
    @ObservedObject var pipManager = PictureInPictureManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var isControlsVisible = false
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var loadingDebounceTask: Task<Void, Never>?
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    @State private var showDiagnosticsHUD = false
    @State private var showSubtitleSettingsSheet = false
    @State private var showEpisodeDrawer = false
    @State private var showPlaybackSettingsSheet = false

    // Snapshot toast & flash
    @State private var snapshotToastMessage: String?
    @State private var showSnapshotFlash = false

    // Pinch to Zoom & Pan
    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero

    // Gestures: Brightness & Volume HUD state
    @State private var brightnessLevel: CGFloat = UIScreen.main.brightness
    @State private var brightnessAtDragStart: CGFloat?
    @State private var volumeLevel: Float = AVAudioSession.sharedInstance().outputVolume
    @State private var volumeAtDragStart: Float?
    @State private var showBrightnessHUD = false
    @State private var showVolumeHUD = false
    @State private var hudDismissTask: Task<Void, Never>?

    private enum DragGestureMode {
        case none
        case brightness
        case volume
        case horizontalSeek
        case dismiss
        case panZoom
    }
    @State private var dragMode: DragGestureMode = .none
    @State private var panSeekTime: TimeInterval = 0
    @State private var panSeekDelta: TimeInterval = 0
    @State private var showPanSeekHUD = false
    @State private var dragDismissOffset: CGFloat = 0

    // Long press temporary 2.0x speed
    @State private var isLongPressSpeedActive = false

    // Screen Lock
    @State private var isLocked = false
    @State private var showUnlockHint = false
    @State private var unlockHintTask: Task<Void, Never>?

    // Finish Time display toggle
    @State private var showFinishTime = false

    // Double tap ripple animation feedback
    @State private var seekFeedback: Int? = nil // -15 or +15

    private let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    public init() {}

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                // Suppress system volume overlay HUD
                HiddenVolumeView()
                    .frame(width: 0, height: 0)
                    .opacity(0)

                // Video rendering surface (AVPlayer or MPV)
                // 默认比例适应模式下仅纵向延伸并保留横向安全区（避开车机左侧导航栏）；在填满屏幕模式（或缩放）下忽略全部安全区，恢复延伸至导航栏下方全屏显示
                playbackSurface
                    .ignoresSafeArea(edges: (playerService.videoGravity == .resizeAspectFill || zoomScale > 1.05) ? .all : [.top, .bottom])

                // Long press 2.0x speed gesture
                LongPressSpeedGestureView(
                    onBegan: {
                        guard !isLocked, playerService.session.status == .playing else { return }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        isLongPressSpeedActive = true
                        playerService.setPlaybackRateTemporary(2.0)
                    },
                    onEnded: {
                        if isLongPressSpeedActive {
                            isLongPressSpeedActive = false
                            playerService.restorePlaybackRate()
                        }
                    }
                )

                // Gesture interaction layer (tap, double-tap, vertical drag brightness/volume, horizontal pan seek)
                gestureLayer(geometry: geometry)

                // Error overlay if playback failed
                if playerService.session.status == .failed,
                   let errorMessage = playerService.session.errorMessage {
                    playbackErrorOverlay(errorMessage)
                }

                // On-screen HUD for Brightness (Left side)
                if showBrightnessHUD {
                    HStack {
                        gestureIndicatorHUD(icon: "sun.max.fill", value: brightnessLevel)
                            .padding(.leading, 36)
                        Spacer()
                    }
                    .transition(.opacity)
                }

                // On-screen HUD for Volume (Right side)
                if showVolumeHUD {
                    HStack {
                        Spacer()
                        let icon = volumeLevel <= 0.001 ? "speaker.slash.fill" : (volumeLevel < 0.33 ? "speaker.wave.1.fill" : (volumeLevel < 0.66 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"))
                        gestureIndicatorHUD(icon: icon, value: CGFloat(volumeLevel))
                            .padding(.trailing, 36)
                    }
                    .transition(.opacity)
                }

                // Horizontal Pan Seek HUD (Center)
                if showPanSeekHUD {
                    panSeekHUD(targetTime: panSeekTime, delta: panSeekDelta)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }

                // Long Press 2.0x Fast Forward Floating Indicator (Top center)
                if isLongPressSpeedActive {
                    HStack(spacing: 8) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(MivuEdition.primaryTint)
                        Text("2.0x 快速播放中")
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 8)
                    .padding(.top, 48)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Seek Ripple Feedback (-15s or +15s)
                if let feedback = seekFeedback {
                    seekRippleView(feedback: feedback)
                        .transition(.opacity)
                }

                // Screen Unlock Floating Button
                if !playerService.isCarPlayActive && isLocked && (showUnlockHint || isControlsVisible) {
                    Button {
                        withAnimation {
                            isLocked = false
                            isControlsVisible = true
                            showUnlockHint = false
                            scheduleHideControls()
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                                .font(.title2)
                                .foregroundColor(MivuEdition.primaryTint)
                            Text("点击解锁")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white.opacity(0.85))
                        }
                        .padding(14)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(color: .black.opacity(0.4), radius: 8)
                    }
                    .padding(.leading, 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .transition(.opacity)
                }

                // Loading & Buffering Overlay with Speed and Percentage
                if playerService.session.status == .loading {
                    loadingBufferingOverlay
                        .transition(.opacity)
                }

                // Stream Diagnostics HUD Overlay
                if showDiagnosticsHUD {
                    diagnosticsHUD
                        .transition(.opacity)
                }

                // Zoom Reset Floating Pill
                if zoomScale > 1.05 {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            zoomScale = 1.0
                            lastZoomScale = 1.0
                            panOffset = .zero
                            lastPanOffset = .zero
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 11, weight: .bold))
                            Text(String.localizedStringWithFormat(String(localized: "%.1f× Zoom"), zoomScale))
                                .font(.caption2.bold().monospacedDigit())
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.3), radius: 6)
                    }
                    .padding(.top, isControlsVisible ? (isCompact(geometry: geometry) ? 50 : 76) : (isCompact(geometry: geometry) ? 24 : 36))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
                }

                // A-B Repeat Floating Indicator
                if playerService.isABRepeatActive {
                    let compact = isCompact(geometry: geometry)
                    HStack(spacing: 8) {
                        Image(systemName: "repeat.1")
                            .foregroundColor(MivuEdition.primaryTint)
                            .font(.caption.bold())
                        let aStr = playerService.repeatPointA != nil ? SOAPParser.formatUPnPTime(playerService.repeatPointA!) : "--:--"
                        let bStr = playerService.repeatPointB != nil ? SOAPParser.formatUPnPTime(playerService.repeatPointB!) : "--:--"
                        Text(String.localizedStringWithFormat(String(localized: "A-B 循环：%@ ~ %@"), aStr, bStr))
                            .font(.caption.bold().monospacedDigit())
                            .foregroundColor(.white)
                        Button {
                            playerService.clearABRepeat()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.white.opacity(0.85))
                                .font(.caption)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 6)
                    .padding(.top, (isControlsVisible ? (compact ? 50 : 76) : (compact ? 24 : 36)) + (zoomScale > 1.05 ? 30 : 0))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
                }

                // Skip Outro Floating Banner
                if playerService.showSkipOutroPrompt && playerService.hasNextInPlaylist {
                    let compact = isCompact(geometry: geometry)
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button {
                                withAnimation {
                                    playerService.playNextInPlaylist()
                                }
                            } label: {
                                HStack(spacing: compact ? 6 : 8) {
                                    Image(systemName: "forward.end.fill")
                                        .font(.system(size: compact ? 10 : 12, weight: .bold))
                                    Text("跳过片尾，播放下一集")
                                        .font(.system(size: compact ? 12 : 14, weight: .bold))
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: compact ? 10 : 12, weight: .bold))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, compact ? 12 : 16)
                                .padding(.vertical, compact ? 7 : 10)
                                .background(MivuEdition.primaryTint)
                                .clipShape(Capsule())
                                .shadow(color: .black.opacity(0.4), radius: 8)
                            }
                            .padding(.trailing, compact ? 16 : 24)
                            .padding(.bottom, isControlsVisible ? (compact ? 55 : (playerService.isCarPlayActive ? 80 : 120)) : (compact ? 20 : 40))
                        }
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.3), value: playerService.showSkipOutroPrompt)
                }

                // Snapshot Flash & Toast Notification
                if showSnapshotFlash {
                    Color.white
                        .ignoresSafeArea()
                        .transition(.opacity)
                }

                if let message = snapshotToastMessage {
                    let compact = isCompact(geometry: geometry)
                    HStack(spacing: 8) {
                        Image(systemName: "camera.fill")
                            .foregroundColor(MivuEdition.primaryTint)
                            .font(.caption.bold())
                        Text(message)
                            .font(.caption.bold())
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 6)
                    .padding(.top, compact ? 36 : 50)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Top & Bottom Controls Overlays
                if isControlsVisible && !isLocked {
                    controlsOverlay(geometry: geometry)
                        .transition(.opacity)
                }
            }
            .onAppear {
                playerService.updateSubtitlePresentation(isPortrait: geometry.size.width < geometry.size.height)
            }
            .onChange(of: geometry.size) { _, newSize in
                playerService.updateSubtitlePresentation(isPortrait: newSize.width < newSize.height)
            }
            .offset(y: dragDismissOffset)
            .scaleEffect(max(0.82, 1.0 - (dragDismissOffset / 1200.0)))
            .opacity(max(0.25, 1.0 - Double(dragDismissOffset / 450.0)))
        }
        .statusBar(hidden: !isControlsVisible || isLocked)
        .onAppear {
            PlaybackOrientation.lockToLandscape()
            if playerService.session.status == .playing {
                isControlsVisible = true
                scheduleHideControls()
            } else if playerService.session.status == .loading {
                isControlsVisible = false
            } else {
                isControlsVisible = true
            }
            brightnessLevel = UIScreen.main.brightness
            volumeLevel = AVAudioSession.sharedInstance().outputVolume
            if playerService.renderSurfaceKind == .mpvSampleBuffer || playerService.renderSurfaceKind == .mpvOpenGLES {
                playerService.activeMPVEngine?.surfaceViewAppeared()
            }
        }
        .onDisappear {
            hideControlsTask?.cancel()
            loadingDebounceTask?.cancel()
            PlaybackOrientation.restoreAppOrientations()
        }
        .onChange(of: playerService.session.status) { _, newStatus in
            switch newStatus {
            case .playing:
                loadingDebounceTask?.cancel()
                withAnimation(.easeInOut(duration: 0.25)) {
                    isControlsVisible = true
                }
                scheduleHideControls()
            case .paused, .stopped, .failed:
                loadingDebounceTask?.cancel()
                hideControlsTask?.cancel()
                withAnimation(.easeInOut(duration: 0.2)) {
                    isControlsVisible = true
                }
            case .loading:
                // 短暂的网络卡顿或切片微小缓冲不打断当前的自隐流程，
                // 仅当卡顿缓冲持续超过 1.5 秒时才显示控制条。
                debounceLoadingControls()
            case .idle:
                break
            }
        }
        .onChange(of: playerService.isCarPlayActive) { _, isActive in
            if isActive {
                isLocked = false
                showUnlockHint = false
            }
        }
        .sheet(isPresented: $showSubtitleSettingsSheet) {
            SubtitleSettingsSheet(playerService: playerService)
        }
        .sheet(isPresented: $showEpisodeDrawer) {
            EpisodeDrawerSheet(playerService: playerService)
        }
        .sheet(isPresented: $showPlaybackSettingsSheet) {
            PlaybackSettingsSheet(playerService: playerService, onSnapshotRequested: { takeSnapshot() })
        }
    }

    // MARK: - Overlays & Surfaces

    @ViewBuilder
    private var playbackSurface: some View {
        Group {
#if canImport(MPV)
            if (playerService.renderSurfaceKind == .mpvSampleBuffer || playerService.renderSurfaceKind == .mpvOpenGLES),
               let engine = playerService.activeMPVEngine {
                MPVVideoPlayerView(engine: engine, videoGravity: playerService.videoGravity)
            } else {
                CustomVideoPlayer(
                    player: playerService.player,
                    videoGravity: playerService.videoGravity
                )
            }
#else
            CustomVideoPlayer(
                player: playerService.player,
                videoGravity: playerService.videoGravity
            )
#endif
        }
        .scaleEffect(zoomScale)
        .offset(panOffset)
    }

    // MARK: - Gesture Interaction Layer

    private func gestureLayer(geometry: GeometryProxy) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .ignoresSafeArea()
            .onTapGesture(count: 2) { location in
                guard !isLocked else {
                    triggerShowUnlockHint()
                    return
                }
                // When zoomed in, double-tap smoothly resets zoom and pan
                if zoomScale > 1.05 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        zoomScale = 1.0
                        lastZoomScale = 1.0
                        panOffset = .zero
                        lastPanOffset = .zero
                    }
                    return
                }
                // Double tap left half -> -15s, right half -> +15s
                if location.x < geometry.size.width / 2 {
                    triggerSeekFeedback(-15)
                    playerService.seek(by: -15)
                } else {
                    triggerSeekFeedback(15)
                    playerService.seek(by: 15)
                }
            }
            .onTapGesture(count: 1) {
                if isLocked {
                    triggerShowUnlockHint()
                } else {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isControlsVisible.toggle()
                    }
                    if isControlsVisible {
                        if playerService.session.status == .playing {
                            scheduleHideControls()
                        }
                    } else {
                        hideControlsTask?.cancel()
                        loadingDebounceTask?.cancel()
                    }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        guard !isLocked else { return }
                        let startX = value.startLocation.x
                        let transX = value.translation.width
                        let transY = value.translation.height

                        if dragMode == .none {
                            if zoomScale > 1.05 {
                                dragMode = .panZoom
                            } else if transY > 20 && abs(transY) > abs(transX) * 1.5 && (value.startLocation.y < geometry.size.height * 0.4 || isControlsVisible) {
                                dragMode = .dismiss
                            } else if abs(transX) > abs(transY) + 6 {
                                dragMode = .horizontalSeek
                                panSeekTime = playerService.session.currentTime
                            } else if startX < geometry.size.width * 0.45 {
                                dragMode = .brightness
                                brightnessAtDragStart = brightnessLevel
                            } else if startX > geometry.size.width * 0.55 {
                                dragMode = .volume
                                volumeAtDragStart = volumeLevel
                            }
                        }

                        switch dragMode {
                        case .panZoom:
                            panOffset = CGSize(
                                width: lastPanOffset.width + transX,
                                height: lastPanOffset.height + transY
                            )

                        case .dismiss:
                            dragDismissOffset = max(0, transY)

                        case .brightness:
                            let start = brightnessAtDragStart ?? UIScreen.main.brightness
                            let delta = -transY / 260.0
                            let newBrightness = min(max(start + delta, 0.0), 1.0)
                            UIScreen.main.brightness = newBrightness
                            brightnessLevel = newBrightness
                            showBrightnessHUD = true

                        case .volume:
                            let start = volumeAtDragStart ?? volumeLevel
                            let delta = Float(-transY / 260.0)
                            let newVolume = min(max(start + delta, 0.0), 1.0)
                            volumeLevel = newVolume
                            playerService.setVolume(newVolume)
                            VolumeController.shared.setVolume(newVolume)
                            showVolumeHUD = true

                        case .horizontalSeek:
                            let duration = max(playerService.session.duration, 1)
                            let delta = TimeInterval(transX * 0.5)
                            panSeekDelta = delta
                            panSeekTime = min(max(playerService.session.currentTime + delta, 0), duration)
                            showPanSeekHUD = true

                        case .none:
                            break
                        }
                    }
                    .onEnded { _ in
                        guard !isLocked else { return }
                        if dragMode == .panZoom {
                            lastPanOffset = panOffset
                        } else if dragMode == .dismiss {
                            if dragDismissOffset > 100 {
                                playerService.stop()
                                dismiss()
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    dragDismissOffset = 0
                                }
                            }
                        } else if dragMode == .horizontalSeek {
                            playerService.seek(to: panSeekTime)
                            showPanSeekHUD = false
                            if playerService.session.status == .playing {
                                scheduleHideControls()
                            }
                        } else if dragMode == .brightness || dragMode == .volume {
                            brightnessAtDragStart = nil
                            volumeAtDragStart = nil
                            triggerDismissHUD()
                        }
                        dragMode = .none
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { val in
                        guard !isLocked else { return }
                        let delta = val / lastZoomScale
                        lastZoomScale = val
                        zoomScale = min(max(zoomScale * delta, 1.0), 4.0)
                    }
                    .onEnded { _ in
                        lastZoomScale = 1.0
                        if zoomScale < 1.06 {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                zoomScale = 1.0
                                lastZoomScale = 1.0
                                panOffset = .zero
                                lastPanOffset = .zero
                            }
                        }
                    }
            )
    }

    private func triggerShowUnlockHint() {
        withAnimation {
            showUnlockHint = true
        }
        triggerDismissUnlockHint()
    }

    private func triggerDismissUnlockHint() {
        unlockHintTask?.cancel()
        unlockHintTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                withAnimation {
                    showUnlockHint = false
                }
            }
        }
    }

    private func panSeekHUD(targetTime: TimeInterval, delta: TimeInterval) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: delta >= 0 ? "forward.fill" : "backward.fill")
                    .font(.title2)
                    .foregroundColor(MivuEdition.primaryTint)
                Text(delta >= 0 ? "+\(SOAPParser.formatUPnPTime(delta))" : "-\(SOAPParser.formatUPnPTime(-delta))")
                    .font(.title2.bold().monospacedDigit())
                    .foregroundColor(.white)
            }
            Text("\(SOAPParser.formatUPnPTime(targetTime)) / \(SOAPParser.formatUPnPTime(playerService.session.duration))")
                .font(.caption.monospacedDigit())
                .foregroundColor(.white.opacity(0.85))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.4), radius: 10)
    }

    private func triggerSeekFeedback(_ seconds: Int) {
        seekFeedback = seconds
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            await MainActor.run { seekFeedback = nil }
        }
    }

    private func triggerDismissHUD() {
        hudDismissTask?.cancel()
        hudDismissTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run {
                withAnimation {
                    showBrightnessHUD = false
                    showVolumeHUD = false
                }
            }
        }
    }

    // MARK: - HUDs

    private func gestureIndicatorHUD(icon: String, value: CGFloat) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.white)

            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 6, height: 110)

                Capsule()
                    .fill(MivuEdition.primaryTint)
                    .frame(width: 6, height: 110 * value)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.3), radius: 8)
    }

    private func seekRippleView(feedback: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: feedback > 0 ? "goforward.15" : "gobackward.15")
                .font(.system(size: 36))
                .foregroundColor(.white)
            Text(feedback > 0 ? "+15s" : "-15s")
                .font(.title3.bold())
                .foregroundColor(.white)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.65))
        .clipShape(Capsule())
    }

    private var loadingBufferingOverlay: some View {
        ProgressView()
            .progressViewStyle(CircularProgressViewStyle(tint: MivuEdition.primaryTint))
            .scaleEffect(1.3)
            .allowsHitTesting(false)
    }

    private func playbackErrorOverlay(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(MivuEdition.primaryTint)
            Text("播放遇到异常")
                .font(.headline)
                .foregroundColor(.white)
            Text(message)
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .lineLimit(4)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(32)
    }

    // MARK: - Responsive Layout Helpers

    private func isCompact(geometry: GeometryProxy) -> Bool {
        playerService.isCarPlayActive
            || geometry.size.height <= 520
            || geometry.safeAreaInsets.leading >= 80
    }

    private func isUltraCompact(geometry: GeometryProxy) -> Bool {
        (playerService.isCarPlayActive && geometry.size.height <= 500)
            || geometry.size.height <= 420
    }

    // MARK: - Controls Overlay

    private func controlsOverlay(geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            topBar(geometry: geometry)

            Spacer()

            centerControls(geometry: geometry)

            Spacer()

            bottomControls(geometry: geometry)
        }
    }

    // MARK: - Top Bar

    private func topBar(geometry: GeometryProxy) -> some View {
        let compact = isCompact(geometry: geometry)
        return HStack(spacing: compact ? 8 : 12) {
            Button {
                playerService.stop()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: compact ? 13 : 16, weight: .bold))
                    .foregroundColor(.white)
                    .padding(compact ? 6 : 10)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }

            VStack(alignment: .leading, spacing: compact ? 1 : 3) {
                Text(playerService.session.currentItem?.title ?? String(localized: "正在播放"))
                    .font(.system(size: compact ? 14 : 17, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    if let originator = playerService.session.currentItem?.originator {
                        Text(originator)
                            .font(.system(size: compact ? 9 : 10))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                    }

                    mediaBadgesView(compact: compact)
                }
            }

            Spacer(minLength: 8)

            // On CarPlay or compact mode, provide clean quick actions in the top bar
            if compact || playerService.isCarPlayActive {
                compactTopActions
                    .layoutPriority(1)
            }
        }
        .buttonStyle(PlayerOverlayButtonStyle())
        .padding(.horizontal, compact ? 14 : 20)
        .padding(.top, compact ? 8 : 16)
        .padding(.bottom, compact ? 10 : 24)
        .background(
            LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: - Compact Top Bar Quick Actions (CarPlay / Compact Displays)

    private var compactTopActions: some View {
        HStack(spacing: 6) {
            if playerService.currentPlaylist.count > 1 {
                Button {
                    showEpisodeDrawer = true
                    scheduleHideControls()
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(6)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
            }

            Menu {
                ForEach(speeds, id: \.self) { speed in
                    Button {
                        playerService.setRate(speed)
                        scheduleHideControls()
                    } label: {
                        HStack {
                            Text("\(String(format: "%.2fx", speed))")
                            if playerService.selectedSpeed == speed {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text(formatSpeedPill(playerService.selectedSpeed))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
            }
            .layoutPriority(1)

            Button {
                showPlaybackSettingsSheet = true
                scheduleHideControls()
            } label: {
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(playerService.volumeBoost > 1.0 ? MivuEdition.primaryTint : .white.opacity(0.9))
                    .padding(6)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }

            // CarPlay 投屏或车载界面下隐藏字幕按钮，避免占用宝贵显示宽度
            if !playerService.isCarPlayActive {
                Menu {
                    Section("字幕轨道") {
                        Button {
                            playerService.setSubtitleTrack(nil)
                            scheduleHideControls()
                        } label: {
                            HStack {
                                Text("关闭字幕")
                                if playerService.selectedSubtitleTrack == nil { Image(systemName: "checkmark") }
                            }
                        }
                        ForEach(playerService.subtitleTracks) { track in
                            Button {
                                playerService.setSubtitleTrack(track)
                                scheduleHideControls()
                            } label: {
                                HStack {
                                    Text(subtitleLabel(track))
                                    if playerService.selectedSubtitleTrack?.id == track.id { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: playerService.selectedSubtitleTrack == nil ? "captions.bubble" : "captions.bubble.fill")
                        .font(.system(size: 11))
                        .foregroundColor(playerService.selectedSubtitleTrack == nil ? .white.opacity(0.9) : MivuEdition.primaryTint)
                        .padding(6)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
            }

            Button {
                playerService.toggleVideoGravity()
                scheduleHideControls()
            } label: {
                Image(systemName: playerService.videoGravity == .resizeAspect ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(6)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
        }
    }

    // MARK: - Center Play/Pause & Seek Controls

    private func centerControls(geometry: GeometryProxy) -> some View {
        let compact = isCompact(geometry: geometry)
        let ultraCompact = isUltraCompact(geometry: geometry)
        let isPaused = playerService.session.status == .paused
        let hasPlaylist = playerService.currentPlaylist.count > 1

        let controlSpacing: CGFloat = compact
            ? (isPaused ? (hasPlaylist ? 10 : 16) : (hasPlaylist ? 16 : 28))
            : (isPaused ? (hasPlaylist ? 16 : 24) : (hasPlaylist ? 32 : 50))

        let playIconSize: CGFloat = compact ? (ultraCompact ? 24 : 28) : 44
        let playPadding: CGFloat = compact ? (ultraCompact ? 11 : 14) : 22
        let seekIconSize: CGFloat = compact ? (isPaused ? 18 : 22) : (isPaused ? 28 : 34)
        let playlistIconSize: CGFloat = compact ? 18 : 24

        return ZStack {
            if !compact && !playerService.isCarPlayActive && playerService.session.status != .loading {
                HStack {
                    Button {
                        withAnimation {
                            isLocked = true
                            isControlsVisible = false
                            showUnlockHint = true
                            triggerDismissUnlockHint()
                        }
                    } label: {
                        Image(systemName: "lock.open")
                            .font(.title3)
                            .foregroundColor(.white.opacity(0.85))
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.3), radius: 6)
                    }
                    .padding(.leading, 32)
                    Spacer()
                }
            }

            if playerService.session.status != .loading {
                HStack(spacing: controlSpacing) {
                if hasPlaylist {
                    Button {
                        playerService.playPreviousInPlaylist()
                        scheduleHideControls()
                    } label: {
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: playlistIconSize))
                            .foregroundColor(playerService.hasPreviousInPlaylist ? .white : .white.opacity(0.3))
                    }
                    .disabled(!playerService.hasPreviousInPlaylist)
                }

                Button {
                    playerService.seek(by: -15)
                    scheduleHideControls()
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: seekIconSize))
                        .foregroundColor(.white)
                }

                // Paused state: Frame Step Backward
                if isPaused {
                    Button {
                        playerService.stepFrame(forward: false)
                    } label: {
                        VStack(spacing: compact ? 1 : 2) {
                            Image(systemName: "backward.frame")
                                .font(.system(size: compact ? 13 : 17, weight: .semibold))
                            Text("逐帧")
                                .font(.system(size: compact ? 7 : 8, weight: .bold))
                        }
                        .foregroundColor(.white.opacity(0.9))
                        .padding(compact ? 5 : 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                    }
                }

                Button {
                    playerService.togglePlayPause()
                    scheduleHideControls()
                } label: {
                    Image(systemName: playerService.session.status == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: playIconSize))
                        .foregroundColor(.white)
                        .padding(playPadding)
                }

                // Paused state: Frame Step Forward
                if isPaused {
                    Button {
                        playerService.stepFrame(forward: true)
                    } label: {
                        VStack(spacing: compact ? 1 : 2) {
                            Image(systemName: "forward.frame")
                                .font(.system(size: compact ? 13 : 17, weight: .semibold))
                            Text("逐帧")
                                .font(.system(size: compact ? 7 : 8, weight: .bold))
                        }
                        .foregroundColor(.white.opacity(0.9))
                        .padding(compact ? 5 : 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                    }
                }

                Button {
                    playerService.seek(by: 15)
                    scheduleHideControls()
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: seekIconSize))
                        .foregroundColor(.white)
                }

                if hasPlaylist {
                    Button {
                        playerService.playNextInPlaylist()
                        scheduleHideControls()
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: playlistIconSize))
                            .foregroundColor(playerService.hasNextInPlaylist ? .white : .white.opacity(0.3))
                    }
                    .disabled(!playerService.hasNextInPlaylist)
                }
            }
            .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Bottom Scrubber & Time Bar

    private func bottomControls(geometry: GeometryProxy) -> some View {
        let compact = isCompact(geometry: geometry)
        let currentTime = isScrubbing ? scrubTime : playerService.session.currentTime
        let duration = max(playerService.session.duration, 1)
        let playProgress = min(max(currentTime / duration, 0), 1.0)
        let bufferProgress = min(max(playerService.session.bufferedTime / duration, 0), 1.0)

        return VStack(spacing: compact ? 6 : 10) {
            // 3-Tier Layered Scrubber
            GeometryReader { geom in
                let totalWidth = geom.size.width
                let trackHeight: CGFloat = compact
                    ? (isScrubbing ? 5 : 3.5)
                    : (isScrubbing ? 7 : 5)
                let thumbSize: CGFloat = compact
                    ? (isScrubbing ? 14 : 10)
                    : (isScrubbing ? 18 : 13)

                ZStack(alignment: .leading) {
                    // 1. Uncached background
                    Capsule()
                        .fill(Color.white.opacity(0.20))
                        .frame(height: trackHeight)

                    // 2. Buffered track
                    Capsule()
                        .fill(Color.white.opacity(0.65))
                        .frame(width: max(0, totalWidth * bufferProgress), height: trackHeight)
                        .animation(.linear(duration: 0.25), value: bufferProgress)

                    // 3. Played track
                    Capsule()
                        .fill(MivuEdition.primaryTint)
                        .frame(width: max(0, totalWidth * playProgress), height: trackHeight)

                    // 4. Chapter tick marks
                    if duration > 0 {
                        ForEach(playerService.chapters) { chapter in
                            if chapter.startTime > 0 && chapter.startTime < duration {
                                let xPos = (chapter.startTime / duration) * totalWidth
                                Rectangle()
                                    .fill(Color.black.opacity(0.85))
                                    .frame(width: 2, height: trackHeight + 2)
                                    .offset(x: max(0, min(xPos - 1, totalWidth - 2)))
                            }
                        }
                    }

                    // 5. A-B Repeat Markers & Region
                    if let a = playerService.repeatPointA, duration > 0 {
                        let aPos = (a / duration) * totalWidth
                        Rectangle()
                            .fill(MivuEdition.primaryTint)
                            .frame(width: 2.5, height: trackHeight + 4)
                            .offset(x: max(0, min(aPos - 1.25, totalWidth - 3)))
                    }
                    if let b = playerService.repeatPointB, duration > 0 {
                        let bPos = (b / duration) * totalWidth
                        Rectangle()
                            .fill(MivuEdition.primaryTint)
                            .frame(width: 2.5, height: trackHeight + 4)
                            .offset(x: max(0, min(bPos - 1.25, totalWidth - 3)))
                    }

                    // 6. Scrubbing thumb knob
                    Circle()
                        .fill(Color.white)
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: .black.opacity(0.45), radius: 3)
                        .offset(x: max(0, min(totalWidth * playProgress - (thumbSize / 2), totalWidth - thumbSize)))
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isScrubbing)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            isScrubbing = true
                            let percent = min(max(val.location.x / totalWidth, 0), 1.0)
                            scrubTime = percent * duration
                        }
                        .onEnded { val in
                            isScrubbing = false
                            let percent = min(max(val.location.x / totalWidth, 0), 1.0)
                            playerService.seek(to: percent * duration)
                            if playerService.session.status == .playing {
                                scheduleHideControls()
                            }
                        }
                )
            }
            .frame(height: compact ? 16 : 22)

            HStack(alignment: .center, spacing: compact ? 4 : 6) {
                Text(SOAPParser.formatUPnPTime(currentTime))
                    .font(.system(size: compact ? 11 : 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .layoutPriority(3)

                if let chapter = currentActiveChapter {
                    Text("·")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.4))
                    Text(chapter.title)
                        .font(.system(size: compact ? 10 : 12))
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: compact ? 160 : 300, alignment: .leading)
                        .layoutPriority(0)
                }

                Spacer(minLength: 4)

                // Real-time Speed Status (hide on very narrow / small screens to prevent crowding)
                if !playerService.session.isLiveStream && (!compact || geometry.size.width >= 650) {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: compact ? 8 : 9, weight: .bold))
                        Text(SOAPParser.formatSpeed(playerService.downloadSpeed))
                            .font(.system(size: compact ? 9 : 10, design: .monospaced))
                    }
                    .foregroundColor(MivuEdition.primaryTint.opacity(0.95))
                    .layoutPriority(1)

                    Spacer(minLength: 4)
                }

                if playerService.session.isLiveStream {
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: compact ? 5 : 6, height: compact ? 5 : 6)
                        Text("LIVE")
                            .font(.system(size: compact ? 10 : 12, weight: .bold))
                            .foregroundColor(.red)
                    }
                    .layoutPriority(3)
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showFinishTime.toggle()
                        }
                    } label: {
                        if showFinishTime {
                            let remaining = max(duration - currentTime, 0)
                            let rate = max(Double(playerService.selectedSpeed), 0.1)
                            let finishDate = Date().addingTimeInterval(remaining / rate)
                            let formatter: DateFormatter = {
                                let df = DateFormatter()
                                df.dateFormat = "HH:mm"
                                return df
                            }()
                            Text(compact
                                 ? String.localizedStringWithFormat(String(localized: "完播 %@"), formatter.string(from: finishDate))
                                 : String.localizedStringWithFormat(String(localized: "预计 %@ 完播"), formatter.string(from: finishDate)))
                                .font(.system(size: compact ? 11 : 12, design: .monospaced))
                                .foregroundColor(MivuEdition.primaryTint.opacity(0.95))
                        } else {
                            let remaining = max(duration - currentTime, 0)
                            Text("-\(SOAPParser.formatUPnPTime(remaining))")
                                .font(.system(size: compact ? 11 : 12, design: .monospaced))
                                .foregroundColor(.white.opacity(0.75))
                        }
                    }
                    .layoutPriority(3)
                }
            }

            // MARK: Bottom Action Toolbar (进度条之下，仅在非紧凑/非车载模式显示)
            if !compact && !playerService.isCarPlayActive {
                bottomActionToolbar
            }
        }
        .padding(.horizontal, compact ? 14 : 20)
        .padding(.bottom, compact ? 8 : 24)
        .padding(.top, compact ? 8 : 16)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: - Diagnostics HUD

    private var diagnosticsHUD: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("STREAM TELEMETRY")
                .font(.caption2.bold())
                .foregroundColor(MivuEdition.primaryTint)

            Text("Status: \(playerService.session.status.rawValue)")
                .font(.caption2.monospaced())
                .foregroundColor(.white)

            Text("Position: \(SOAPParser.formatUPnPTime(playerService.session.currentTime)) / \(SOAPParser.formatUPnPTime(playerService.session.duration))")
                .font(.caption2.monospaced())
                .foregroundColor(.white)

            Text("Buffer: \(SOAPParser.formatUPnPTime(playerService.session.bufferedTime)) (\(Int((playerService.session.duration > 0 ? playerService.session.bufferedTime / playerService.session.duration : 0) * 100))%)")
                .font(.caption2.monospaced())
                .foregroundColor(.white)

            Text("Download: \(SOAPParser.formatSpeed(playerService.downloadSpeed))")
                .font(.caption2.monospaced())
                .foregroundColor(MivuEdition.primaryTint)

            Text("Speed: \(String(format: "%.2fx", playerService.selectedSpeed)) | Gravity: \(playerService.videoGravity == .resizeAspect ? "Aspect" : "Fill")")
                .font(.caption2.monospaced())
                .foregroundColor(.white)

            Text("Surface: \(playerService.renderSurfaceKind.rawValue)")
                .font(.caption2.monospaced())
                .foregroundColor(.yellow)

            if let diag = playerService.activeMPVRenderDiagnostic {
                Text("MPV: \(diag)")
                    .font(.caption2.monospaced())
                    .foregroundColor(.green)
            }

            if let url = playerService.session.currentItem?.url {
                Text("Host: \(url.host ?? "localhost")")
                    .font(.caption2.monospaced())
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(MivuEdition.primaryTint.opacity(0.4), lineWidth: 1)
        )
        .padding(.leading, 16)
        .padding(.top, 85)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Bottom Action Toolbar

    private var bottomActionToolbar: some View {
        HStack(spacing: 8) {
            // Left: Chapters & Playlist (选集 / 章节)
            if !playerService.chapters.isEmpty {
                chapterMenuButton
            }
            if playerService.currentPlaylist.count > 1 {
                playlistMenuButton
            }

            Spacer()

            // Right: Playback options
            speedMenuButton
            if !playerService.isCarPlayActive {
                subtitlesMenuButton
            }
            audioTracksMenuButton
            snapshotButton
            playbackSettingsButton
            aspectRatioButton
            if playerService.renderSurfaceKind == .nativeAVPlayer,
               (PictureInPictureManager.shared.isPiPPossible || AVPictureInPictureController.isPictureInPictureSupported()) {
                pipButton
            }
            diagnosticsButton
            if playerService.renderSurfaceKind == .nativeAVPlayer {
                AirPlayRoutePickerView()
                    .frame(width: 30, height: 30)
            }
        }
        .padding(.top, 4)
    }

    private var snapshotButton: some View {
        Button {
            takeSnapshot()
        } label: {
            Image(systemName: "camera")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.9))
                .padding(7)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
    }

    private var playbackSettingsButton: some View {
        Button {
            showPlaybackSettingsSheet = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.9))
                .padding(7)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
    }

    private var chapterMenuButton: some View {
        Menu {
            Section(String.localizedStringWithFormat(String(localized: "章节列表 (%d)"), playerService.chapters.count)) {
                ForEach(playerService.chapters) { chapter in
                    Button {
                        playerService.seek(to: chapter.startTime)
                        scheduleHideControls()
                    } label: {
                        HStack {
                            Text(chapter.title)
                            Spacer()
                            Text(SOAPParser.formatUPnPTime(chapter.startTime))
                            if isCurrentChapter(chapter) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("章节")
                    .font(.caption2.bold())
            }
            .foregroundColor(MivuEdition.primaryTint)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
        }
    }

    private var playlistMenuButton: some View {
        Button {
            showEpisodeDrawer = true
            scheduleHideControls()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 11, weight: .semibold))
                Text("选集")
                    .font(.caption2.bold())
            }
            .foregroundColor(.white.opacity(0.9))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
        }
    }

    private var speedMenuButton: some View {
        Menu {
            ForEach(speeds, id: \.self) { speed in
                Button {
                    playerService.setRate(speed)
                    scheduleHideControls()
                } label: {
                    HStack {
                        Text("\(String(format: "%.2fx", speed))")
                        if playerService.selectedSpeed == speed {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(formatSpeedPill(playerService.selectedSpeed))
                .font(.caption.bold())
                .foregroundColor(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
        }
    }

    private var subtitlesMenuButton: some View {
        Menu {
            Section(String.localizedStringWithFormat(String(localized: "字幕大小 (%lld%%)"), Int(playerService.subtitleUserScale * 100))) {
                ForEach([
                    ("极小 (75%)", 0.75),
                    ("较小 (85%)", 0.85),
                    ("标准 (100%)", 1.00),
                    ("较大 (120%)", 1.20),
                    ("特大 (140%)", 1.40),
                    ("极大 (160%)", 1.60)
                ], id: \.1) { label, scale in
                    Button {
                        playerService.setSubtitleUserScale(scale)
                    } label: {
                        HStack {
                            Text(label)
                            if abs(playerService.subtitleUserScale - scale) < 0.02 {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            let subtitleSyncStatus = playerService.subtitleDelay == 0 ? String(localized: "已对齐") : String(format: "%+.1fs", playerService.subtitleDelay)
            Section(String.localizedStringWithFormat(String(localized: "字幕同步 (%@)"), subtitleSyncStatus)) {
                Button {
                    playerService.setSubtitleDelay(playerService.subtitleDelay - 0.5)
                } label: {
                    Text("提前 0.5 秒 (-0.5s)")
                }
                Button {
                    playerService.setSubtitleDelay(playerService.subtitleDelay + 0.5)
                } label: {
                    Text("延迟 0.5 秒 (+0.5s)")
                }
                if playerService.subtitleDelay != 0 {
                    Button {
                        playerService.setSubtitleDelay(0)
                    } label: {
                        Text("重置延迟 (0.0s)")
                    }
                }
            }

            Button {
                showSubtitleSettingsSheet = true
            } label: {
                Label("字幕详细设置与滑块...", systemImage: "slider.horizontal.3")
            }

            Section("字幕轨道") {
                Button {
                    playerService.setSubtitleTrack(nil)
                    scheduleHideControls()
                } label: {
                    HStack { Text("关闭字幕"); if playerService.selectedSubtitleTrack == nil { Image(systemName: "checkmark") } }
                }
                if playerService.subtitleTracks.isEmpty {
                    Text("暂无字幕轨道")
                } else {
                    ForEach(playerService.subtitleTracks) { track in
                        Button {
                            playerService.setSubtitleTrack(track)
                            scheduleHideControls()
                        } label: {
                            HStack {
                                Text(subtitleLabel(track))
                                if playerService.selectedSubtitleTrack?.id == track.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: playerService.selectedSubtitleTrack == nil ? "captions.bubble" : "captions.bubble.fill")
                .font(.system(size: 14))
                .foregroundColor(playerService.selectedSubtitleTrack == nil ? .white.opacity(0.9) : MivuEdition.primaryTint)
                .padding(7)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
    }

    private var audioTracksMenuButton: some View {
        Menu {
            Section("音频轨道") {
                if playerService.audioTracks.isEmpty {
                    Text("默认音轨")
                } else {
                    ForEach(playerService.audioTracks) { track in
                        Button {
                            playerService.setAudioTrack(track)
                            scheduleHideControls()
                        } label: {
                            HStack {
                                Text(audioTrackLabel(track))
                                if playerService.selectedAudioTrack?.id == track.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: (playerService.audioTracks.count > 1 || playerService.selectedAudioTrack != nil) ? "speaker.wave.2.fill" : "speaker.wave.2")
                .font(.system(size: 14))
                .foregroundColor(playerService.audioTracks.count > 1 ? MivuEdition.primaryTint : .white.opacity(0.9))
                .padding(7)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
    }

    private var aspectRatioButton: some View {
        Button {
            playerService.toggleVideoGravity()
            scheduleHideControls()
        } label: {
            Image(systemName: playerService.videoGravity == .resizeAspect ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.9))
                .padding(7)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
    }

    private var pipButton: some View {
        Button {
            PictureInPictureManager.shared.togglePiP()
        } label: {
            Image(systemName: PictureInPictureManager.shared.isPiPActive ? "pip.exit" : "pip.enter")
                .font(.system(size: 14))
                .foregroundColor(PictureInPictureManager.shared.isPiPActive ? MivuEdition.primaryTint : .white.opacity(0.9))
                .padding(7)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
    }

    private var diagnosticsButton: some View {
        Button {
            withAnimation {
                showDiagnosticsHUD.toggle()
            }
            scheduleHideControls()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 14))
                .foregroundColor(showDiagnosticsHUD ? MivuEdition.primaryTint : .white.opacity(0.9))
                .padding(7)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
    }

    private func scheduleHideControls() {
        hideControlsTask?.cancel()
        loadingDebounceTask?.cancel()
        // 仅在暂停或停止等需要用户操作的状态下保持控制条常驻，加载状态不强制展示控制条
        guard playerService.session.status == .playing else {
            if playerService.session.status == .paused || playerService.session.status == .stopped {
                isControlsVisible = true
            }
            return
        }
        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.25)) {
                    if playerService.session.status == .playing {
                        isControlsVisible = false
                    }
                }
            }
        }
    }

    private func debounceLoadingControls() {
        loadingDebounceTask?.cancel()
        loadingDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if playerService.session.status == .loading {
                        hideControlsTask?.cancel()
                        isControlsVisible = true
                    }
                }
            }
        }
    }

    private func formatSpeedPill(_ speed: Float) -> String {
        if speed.truncatingRemainder(dividingBy: 0.1) < 0.01 {
            return String(format: "%.1fx", speed)
        } else {
            return String(format: "%.2fx", speed)
        }
    }

    private func subtitleLabel(_ track: SubtitleTrack) -> String {
        let base = track.title ?? track.language ?? String.localizedStringWithFormat(String(localized: "字幕 %@"), track.id)
        let flags = [track.isDefault ? String(localized: "默认") : nil, track.isForced ? String(localized: "强制") : nil].compactMap { $0 }
        let capability = track.format == .pgs || track.format == .vobsub ? String(localized: "图片") : track.format.rawValue.uppercased()
        return flags.isEmpty
            ? String.localizedStringWithFormat(String(localized: "%@ · %@"), base, capability)
            : String.localizedStringWithFormat(String(localized: "%@ (%@) · %@"), base, flags.joined(separator: ", "), capability)
    }

    private func audioTrackLabel(_ track: AudioTrack) -> String {
        let base = track.title ?? track.language ?? String.localizedStringWithFormat(String(localized: "音轨 %@"), track.id)
        return track.isDefault ? String.localizedStringWithFormat(String(localized: "%@ (Default)"), base) : base
    }

    // MARK: - Media Badges & Chapter Helpers

    @ViewBuilder
    private func mediaBadgesView(compact: Bool = false) -> some View {
        let allBadges = derivedBadges
        let badges = compact ? Array(allBadges.prefix(3)) : allBadges
        if !badges.isEmpty {
            HStack(spacing: compact ? 3 : 4) {
                ForEach(badges, id: \.self) { badge in
                    badgePill(badge, compact: compact)
                }
            }
        }
    }

    private func badgePill(_ text: String, compact: Bool = false) -> some View {
        Text(text)
            .font(.system(size: compact ? 7.5 : 9, weight: .bold))
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, compact ? 3 : 4)
            .padding(.vertical, compact ? 1 : 1.5)
            .background(Color.white.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var derivedBadges: [String] {
        var badges: [String] = []
        let item = playerService.session.currentItem
        let titleLower = (item?.title ?? "").lowercased()
        let urlLower = (item?.url.absoluteString ?? "").lowercased()
        let codecHintLower = (item?.videoCodecHint ?? "").lowercased()

        // 1. Resolution
        if titleLower.contains("4k") || titleLower.contains("2160p") || urlLower.contains("2160p") || urlLower.contains("4k") {
            badges.append("4K")
        } else if titleLower.contains("1080p") || urlLower.contains("1080p") {
            badges.append("1080p")
        } else if titleLower.contains("720p") || urlLower.contains("720p") {
            badges.append("720p")
        }

        // 2. Dynamic Range
        if titleLower.contains("dv") || titleLower.contains("dovi") || titleLower.contains("dolby vision") {
            badges.append("DOVI")
        } else if titleLower.contains("hdr10+") {
            badges.append("HDR10+")
        } else if titleLower.contains("hdr") {
            badges.append("HDR")
        }

        // 3. Video Codec
        if codecHintLower.contains("hevc") || codecHintLower.contains("h265") || titleLower.contains("hevc") || titleLower.contains("x265") || titleLower.contains("h.265") || titleLower.contains("h265") {
            badges.append("HEVC")
        } else if codecHintLower.contains("av1") || titleLower.contains("av1") {
            badges.append("AV1")
        } else if codecHintLower.contains("avc") || codecHintLower.contains("h264") || titleLower.contains("x264") || titleLower.contains("h.264") || titleLower.contains("h264") {
            badges.append("H.264")
        }

        // 4. Audio Specs
        let audioTrackTitle = (playerService.selectedAudioTrack?.title ?? "").lowercased()
        if titleLower.contains("atmos") || audioTrackTitle.contains("atmos") {
            badges.append("ATMOS")
        } else if titleLower.contains("truehd") || audioTrackTitle.contains("truehd") {
            badges.append("TrueHD")
        } else if titleLower.contains("dts-hd") || titleLower.contains("dtshd") || audioTrackTitle.contains("dts-hd") {
            badges.append("DTS-HD")
        } else if titleLower.contains("dts") || audioTrackTitle.contains("dts") {
            badges.append("DTS")
        } else if titleLower.contains("7.1") || audioTrackTitle.contains("7.1") {
            badges.append("7.1")
        } else if titleLower.contains("5.1") || audioTrackTitle.contains("5.1") {
            badges.append("5.1")
        }

        // 5. Container format
        if let container = item?.containerHint?.uppercased(), !container.isEmpty {
            badges.append(container)
        } else {
            let ext = item?.url.pathExtension.uppercased() ?? ""
            if !ext.isEmpty && ["MKV", "MP4", "TS", "M2TS", "MOV"].contains(ext) {
                badges.append(ext)
            }
        }

        return badges
    }

    private func isCurrentChapter(_ chapter: PlaybackChapter) -> Bool {
        let current = playerService.session.currentTime
        return current >= chapter.startTime && (current < chapter.startTime + chapter.duration || chapter.duration <= 0)
    }

    private var currentActiveChapter: PlaybackChapter? {
        let current = isScrubbing ? scrubTime : playerService.session.currentTime
        return playerService.chapters.first { chapter in
            current >= chapter.startTime && (current < chapter.startTime + chapter.duration || chapter.duration <= 0)
        }
    }

    // MARK: - Snapshot & Toast Helpers

    private func takeSnapshot() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        withAnimation(.easeOut(duration: 0.12)) {
            showSnapshotFlash = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeIn(duration: 0.18)) {
                showSnapshotFlash = false
            }
        }

        // 1. If MPV engine is active, capture lossless frame via MPV's native screenshot engine
        if playerService.renderSurfaceKind == .mpvSampleBuffer || playerService.renderSurfaceKind == .mpvOpenGLES {
            let tempPath = NSTemporaryDirectory().appending("mivu_snapshot_\(UUID().uuidString).png")
            if playerService.takeSnapshot(toFile: tempPath, includeSubtitles: true),
               let image = UIImage(contentsOfFile: tempPath) {
                try? FileManager.default.removeItem(atPath: tempPath)
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                showToast("已保存原画截图至相册")
                return
            }
        }

        // 2. If AVPlayer has current asset, extract lossless raw frame via AVAssetImageGenerator
        if let asset = playerService.player.currentItem?.asset, playerService.renderSurfaceKind == .nativeAVPlayer {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let cmTime = CMTime(seconds: playerService.session.currentTime, preferredTimescale: 600)

            Task.detached(priority: .userInitiated) {
                do {
                    let cgImage = try generator.copyCGImage(at: cmTime, actualTime: nil)
                    let image = UIImage(cgImage: cgImage)
                    await MainActor.run {
                        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                        showToast("已保存原画截图至相册")
                    }
                } catch {
                    await MainActor.run {
                        captureScreenSnapshot()
                    }
                }
            }
        } else {
            captureScreenSnapshot()
        }
    }

    private func captureScreenSnapshot() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else {
            showToast("截图保存失败")
            return
        }

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        showToast("已保存画面截图至相册")
    }

    private func showToast(_ message: String) {
        withAnimation {
            snapshotToastMessage = message
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run {
                withAnimation {
                    if snapshotToastMessage == message {
                        snapshotToastMessage = nil
                    }
                }
            }
        }
    }
}

private struct PlayerOverlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - AVPlayer & MPV Layer Wrappers

#if canImport(MPV)
public struct MPVVideoPlayerView: UIViewRepresentable {
    public let engine: MPVPlayerEngine
    public var videoGravity: AVLayerVideoGravity = .resizeAspect

    public init(engine: MPVPlayerEngine, videoGravity: AVLayerVideoGravity = .resizeAspect) {
        self.engine = engine
        self.videoGravity = videoGravity
    }

    public func makeUIView(context: Context) -> MPVSampleBufferView {
        let view = engine.makeSampleBufferView() ?? MPVSampleBufferView(engine: engine)
        view.isUserInteractionEnabled = false
        view.sampleBufferDisplayLayer.videoGravity = videoGravity
        return view
    }

    public func updateUIView(_ view: MPVSampleBufferView, context: Context) {
        view.engine = engine
        view.isUserInteractionEnabled = false
        if view.sampleBufferDisplayLayer.videoGravity != videoGravity {
            view.sampleBufferDisplayLayer.videoGravity = videoGravity
        }
    }
}
#endif

public struct CustomVideoPlayer: UIViewControllerRepresentable {
    public let player: AVPlayer
    public let videoGravity: AVLayerVideoGravity

    public init(player: AVPlayer, videoGravity: AVLayerVideoGravity = .resizeAspect) {
        self.player = player
        self.videoGravity = videoGravity
    }

    public func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = videoGravity
        controller.allowsPictureInPicturePlayback = true
        controller.updatesNowPlayingInfoCenter = false
        return controller
    }

    public func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
        if uiViewController.videoGravity != videoGravity {
            uiViewController.videoGravity = videoGravity
        }
        DispatchQueue.main.async {
            if let playerLayer = self.findPlayerLayer(in: uiViewController.view) {
                PictureInPictureManager.shared.setup(with: playerLayer)
            }
        }
    }

    private func findPlayerLayer(in view: UIView) -> AVPlayerLayer? {
        if let layer = view.layer as? AVPlayerLayer { return layer }
        for subview in view.subviews {
            if let found = findPlayerLayer(in: subview) { return found }
        }
        for sublayer in view.layer.sublayers ?? [] {
            if let playerLayer = sublayer as? AVPlayerLayer { return playerLayer }
        }
        return nil
    }
}

// MARK: - Picture in Picture Manager

@MainActor
public final class PictureInPictureManager: NSObject, ObservableObject {
    public static let shared = PictureInPictureManager()

    @Published public var isPiPPossible = false
    @Published public var isPiPActive = false

    private var pipController: AVPictureInPictureController?

    public func setup(with playerLayer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        if pipController?.playerLayer !== playerLayer {
            pipController = AVPictureInPictureController(playerLayer: playerLayer)
            pipController?.delegate = self
            isPiPPossible = pipController?.isPictureInPicturePossible ?? false
        }
    }

    public func togglePiP() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else if pipController.isPictureInPicturePossible {
            pipController.startPictureInPicture()
        }
    }
}

extension PictureInPictureManager: AVPictureInPictureControllerDelegate {
    public nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            self.isPiPActive = true
        }
    }

    public nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            self.isPiPActive = false
        }
    }

    public nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        MainActor.assumeIsolated {
            completionHandler(true)
        }
    }
}

// MARK: - Long Press Speed Gesture Wrapper

struct LongPressSpeedGestureView: UIViewRepresentable {
    var onBegan: () -> Void
    var onEnded: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = TouchForwardingView()
        view.backgroundColor = .clear
        let recognizer = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        recognizer.minimumPressDuration = 0.45
        recognizer.allowableMovement = 25
        recognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegan: onBegan, onEnded: onEnded)
    }

    final class Coordinator: NSObject {
        var onBegan: () -> Void
        var onEnded: () -> Void

        init(onBegan: @escaping () -> Void, onEnded: @escaping () -> Void) {
            self.onBegan = onBegan
            self.onEnded = onEnded
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                onBegan()
            case .ended, .cancelled, .failed:
                onEnded()
            default:
                break
            }
        }
    }

    final class TouchForwardingView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let view = super.hitTest(point, with: event)
            return view === self ? self : view
        }
    }
}

// MARK: - Volume Controller & Suppressor

final class VolumeController {
    static let shared = VolumeController()
    private var volumeSlider: UISlider?

    init() {
        let volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        volumeView.alpha = 0.0001
        for subview in volumeView.subviews {
            if let slider = subview as? UISlider {
                self.volumeSlider = slider
                break
            }
        }
    }

    func setVolume(_ value: Float) {
        DispatchQueue.main.async { [weak self] in
            self?.volumeSlider?.setValue(value, animated: false)
        }
    }
}

public struct HiddenVolumeView: UIViewRepresentable {
    public init() {}
    public func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        view.alpha = 0.0001
        view.clipsToBounds = true
        return view
    }
    public func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

// MARK: - AirPlay Button Wrapper

public struct AirPlayRoutePickerView: UIViewRepresentable {
    public init() {}

    public func makeUIView(context: Context) -> AVRoutePickerView {
        let routePicker = AVRoutePickerView()
        routePicker.tintColor = .white
        routePicker.activeTintColor = .systemOrange
        routePicker.prioritizesVideoDevices = true
        return routePicker
    }

    public func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Subtitle Settings Sheet

struct SubtitleSettingsSheet: View {
    @ObservedObject var playerService: PlayerService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Live preview box
                    VStack(spacing: 8) {
                        Text("实时显示预览")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        ZStack {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color(uiColor: .secondarySystemBackground))
                                .frame(height: 100)

                            VStack(spacing: 6) {
                                Text("这是中文字幕显示效果")
                                    .font(.system(size: 18 * playerService.subtitleUserScale, weight: .medium))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.4)

                                Text("Subtitle Preview • \(Int(playerService.subtitleUserScale * 100))%")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.horizontal, 20)

                    // Slider & Percentage readout
                    VStack(spacing: 12) {
                        HStack {
                            Text("字体缩放大小")
                                .font(.subheadline.bold())
                            Spacer()
                            Text("\(Int(playerService.subtitleUserScale * 100))%")
                                .font(.headline.monospacedDigit())
                                .foregroundColor(MivuEdition.primaryTint)
                        }

                        HStack(spacing: 12) {
                            Button {
                                playerService.setSubtitleUserScale(playerService.subtitleUserScale - 0.05)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                            }

                            Slider(
                                value: Binding(
                                    get: { playerService.subtitleUserScale },
                                    set: { playerService.setSubtitleUserScale($0) }
                                ),
                                in: 0.5...2.0,
                                step: 0.05
                            )
                            .tint(MivuEdition.primaryTint)

                            Button {
                                playerService.setSubtitleUserScale(playerService.subtitleUserScale + 0.05)
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                            }
                        }

                        // Quick Presets Pills
                        HStack(spacing: 8) {
                            ForEach([0.75, 0.85, 1.0, 1.20, 1.40, 1.60], id: \.self) { scale in
                                let isSelected = abs(playerService.subtitleUserScale - scale) < 0.02
                                Button {
                                    playerService.setSubtitleUserScale(scale)
                                } label: {
                                    Text("\(Int(scale * 100))%")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(isSelected ? MivuEdition.primaryTint : Color(uiColor: .tertiarySystemFill))
                                        .foregroundColor(isSelected ? .white : .primary)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 20)

                    // Subtitle Delay Calibration Section
                    VStack(spacing: 12) {
                        HStack {
                            Text("字幕时间轴微调 (延迟)")
                                .font(.subheadline.bold())
                            Spacer()
                            Text(playerService.subtitleDelay == 0 ? String(localized: "0.0s (已对齐)") : String(format: "%+.1fs", playerService.subtitleDelay))
                                .font(.headline.monospacedDigit())
                                .foregroundColor(playerService.subtitleDelay == 0 ? .secondary : MivuEdition.primaryTint)
                        }

                        HStack(spacing: 8) {
                            Button("-0.5s") {
                                playerService.setSubtitleDelay(playerService.subtitleDelay - 0.5)
                            }
                            .buttonStyle(.bordered)
                            .tint(.secondary)

                            Button("-0.1s") {
                                playerService.setSubtitleDelay(playerService.subtitleDelay - 0.1)
                            }
                            .buttonStyle(.bordered)
                            .tint(.secondary)

                            Button("复位") {
                                playerService.setSubtitleDelay(0)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(playerService.subtitleDelay == 0 ? .secondary.opacity(0.4) : MivuEdition.primaryTint)

                            Button("+0.1s") {
                                playerService.setSubtitleDelay(playerService.subtitleDelay + 0.1)
                            }
                            .buttonStyle(.bordered)
                            .tint(.secondary)

                            Button("+0.5s") {
                                playerService.setSubtitleDelay(playerService.subtitleDelay + 0.5)
                            }
                            .buttonStyle(.bordered)
                            .tint(.secondary)
                        }
                        .font(.caption.bold())

                        Text("如果字幕出现过早，请点按增加延迟（+）；若字幕出现过迟，请减少延迟（-）。支持 AVPlayer 与 MPV 双引擎无缝校准。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 20)

                    // Portrait adaptation toggle
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("竖屏适度缩小 (0.85x)", isOn: Binding(
                            get: { playerService.subtitleAutoPortraitScale },
                            set: { playerService.setSubtitleAutoPortraitScale($0) }
                        ))
                        .tint(MivuEdition.primaryTint)

                        Text("在竖屏模式下轻微缩小字幕比例，避免横屏视频在小窗口下过度遮挡画面。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 20)

                    // Reset button
                    Button {
                        playerService.setSubtitleUserScale(1.0)
                        playerService.setSubtitleAutoPortraitScale(true)
                        playerService.setSubtitleDelay(0)
                    } label: {
                        Text("重置为默认设置")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
                .padding(.top, 16)
            }
            .navigationTitle("字幕自定义设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Episode Drawer Sheet (选集半屏抽屉)

struct EpisodeDrawerSheet: View {
    @ObservedObject var playerService: PlayerService
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.adaptive(minimum: 90, maximum: 140), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Array(playerService.currentPlaylist.enumerated()), id: \.element.id) { index, item in
                        let isCurrent = item.id == playerService.session.currentItem?.id
                        Button {
                            playerService.loadAndPlay(item: item)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(String.localizedStringWithFormat(String(localized: "第 %d 集"), index + 1))
                                        .font(.caption2.bold())
                                        .foregroundColor(isCurrent ? MivuEdition.primaryTint : .secondary)
                                    Spacer()
                                    if isCurrent {
                                        Image(systemName: playerService.session.status == .playing ? "waveform" : "play.fill")
                                            .font(.caption2)
                                            .foregroundColor(MivuEdition.primaryTint)
                                    }
                                }

                                Text(item.title)
                                    .font(.subheadline.weight(isCurrent ? .bold : .medium))
                                    .foregroundColor(isCurrent ? MivuEdition.primaryTint : .primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(isCurrent ? MivuEdition.primaryTint.opacity(0.12) : Color(uiColor: .secondarySystemBackground))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(isCurrent ? MivuEdition.primaryTint : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle(String.localizedStringWithFormat(String(localized: "选集 (%d 集)"), playerService.currentPlaylist.count))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Playback Settings Sheet (播放设置中心)

struct PlaybackSettingsSheet: View {
    @ObservedObject var playerService: PlayerService
    var onSnapshotRequested: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var volumeBoostBinding: Binding<Double> {
        Binding<Double>(
            get: { Double(playerService.volumeBoost) },
            set: { playerService.setVolumeBoost(Float($0)) }
        )
    }

    private var subtitleOffsetBinding: Binding<Double> {
        Binding<Double>(
            get: { Double(100 - playerService.subtitleVerticalOffset) / 100.0 },
            set: { playerService.setSubtitleVerticalOffset(100 - Int(($0 * 100.0).rounded())) }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Audio Enhancement
                Section {
                    Toggle("人声增强 (Voice Boost)", isOn: Binding(
                        get: { playerService.isVoiceBoostEnabled },
                        set: { playerService.setVoiceBoost($0) }
                    ))
                    .tint(MivuEdition.primaryTint)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("音量超量增益 (Volume Boost)")
                            Spacer()
                            Text("\(Int(playerService.volumeBoost * 100))%")
                                .font(.subheadline.bold().monospacedDigit())
                                .foregroundColor(playerService.volumeBoost > 1.0 ? MivuEdition.primaryTint : .secondary)
                        }

                        Slider(value: volumeBoostBinding, in: 1.0...2.0, step: 0.05)
                            .tint(MivuEdition.primaryTint)

                        HStack {
                            Text("100% (标准)")
                            Spacer()
                            Text("200% (超量)")
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("音频与对白增强")
                } footer: {
                    Text("人声增强运用动态规格化压缩（dynaudnorm），提升低语对白响度并平衡爆炸声。超量增益最高可将音量放大至 200%。")
                        .font(.caption2)
                }

                // MARK: - Smart Skipping & Rewind
                Section {
                    Picker("恢复播放自动回退", selection: Binding(
                        get: { playerService.rewindOnResumeSeconds },
                        set: { playerService.setRewindOnResumeSeconds($0) }
                    )) {
                        Text("关闭").tag(0.0)
                        Text("3 秒").tag(3.0)
                        Text("5 秒").tag(5.0)
                    }

                    Picker("智能跳过片头", selection: Binding(
                        get: { playerService.skipIntroSeconds },
                        set: { playerService.setSkipIntroSeconds($0) }
                    )) {
                        Text("关闭").tag(0.0)
                        Text("15 秒").tag(15.0)
                        Text("30 秒").tag(30.0)
                        Text("60 秒").tag(60.0)
                        Text("90 秒").tag(90.0)
                        Text("120 秒").tag(120.0)
                    }

                    Picker("智能跳过片尾", selection: Binding(
                        get: { playerService.skipOutroSeconds },
                        set: { playerService.setSkipOutroSeconds($0) }
                    )) {
                        Text("关闭").tag(0.0)
                        Text("30 秒").tag(30.0)
                        Text("60 秒").tag(60.0)
                        Text("90 秒").tag(90.0)
                        Text("120 秒").tag(120.0)
                        Text("180 秒").tag(180.0)
                    }
                } header: {
                    Text("智能跳过与播放记忆")
                } footer: {
                    Text("恢复播放回退帮助您重新衔接前情；片尾临近时右下角会浮现『跳过片尾，播放下一集』快捷浮窗。")
                        .font(.caption2)
                }

                // MARK: - Subtitle Fine-Tuning & Dual Subtitles
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("字幕垂直高度偏移")
                            Spacer()
                            let offsetPercent = 100 - playerService.subtitleVerticalOffset
                        Text(offsetPercent == 0
                             ? String(localized: "置底 (0%)")
                             : String.localizedStringWithFormat(String(localized: "+%d%% 向上"), offsetPercent))
                                .font(.subheadline.bold().monospacedDigit())
                                .foregroundColor(offsetPercent > 0 ? MivuEdition.primaryTint : .secondary)
                        }

                        Slider(value: subtitleOffsetBinding, in: 0.0...0.5, step: 0.05)
                            .tint(MivuEdition.primaryTint)
                    }
                    .padding(.vertical, 4)

                    if playerService.subtitleTracks.count > 1 {
                        Picker("第二字幕 (次字幕)", selection: Binding<String>(
                            get: { playerService.secondarySubtitleTrack?.id ?? "" },
                            set: { selectedId in
                                if selectedId.isEmpty {
                                    playerService.setSecondarySubtitleTrack(nil)
                                } else {
                                    let track = playerService.subtitleTracks.first { $0.id == selectedId }
                                    playerService.setSecondarySubtitleTrack(track)
                                }
                            }
                        )) {
                            Text("无 (仅单字幕)").tag("")
                            ForEach(playerService.subtitleTracks) { track in
                                if track.id != playerService.selectedSubtitleTrack?.id {
                                    Text(track.title ?? track.language ?? String.localizedStringWithFormat(String(localized: "字幕 %@"), track.id)).tag(track.id)
                                }
                            }
                        }
                    }
                } header: {
                    Text("字幕垂直位置与双字幕")
                } footer: {
                    Text("适当上移字幕可避免与内嵌压制字幕或底部弹幕重叠。双字幕允许您同时展示两种语言轨道。")
                        .font(.caption2)
                }

                // MARK: - A-B Repeat
                Section {
                    let currentTime = playerService.session.currentTime
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("A-B 循环区间")
                                .font(.subheadline)
                            let aStr = playerService.repeatPointA != nil ? SOAPParser.formatUPnPTime(playerService.repeatPointA!) : "未设"
                            let bStr = playerService.repeatPointB != nil ? SOAPParser.formatUPnPTime(playerService.repeatPointB!) : "未设"
                            Text("A: [\(aStr)]  →  B: [\(bStr)]")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if playerService.isABRepeatActive {
                            Button("清除循环") {
                                playerService.clearABRepeat()
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            playerService.setRepeatPointA()
                        } label: {
                            HStack {
                                Image(systemName: "a.circle.fill")
                                Text(String.localizedStringWithFormat(String(localized: "设为 A 点 (%@)"), SOAPParser.formatUPnPTime(currentTime)))
                            }
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(MivuEdition.primaryTint)

                        Button {
                            playerService.setRepeatPointB()
                        } label: {
                            HStack {
                                Image(systemName: "b.circle.fill")
                                Text(String.localizedStringWithFormat(String(localized: "设为 B 点 (%@)"), SOAPParser.formatUPnPTime(currentTime)))
                            }
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(MivuEdition.primaryTint)
                        .disabled(playerService.repeatPointA == nil || currentTime <= (playerService.repeatPointA ?? 0))
                    }
                } header: {
                    Text("A-B 点循环片段播放")
                } footer: {
                    Text("设定 A 点与 B 点后，播放器将在区间内自动无限循环，适合反复观摩精彩瞬间或外语精听。")
                        .font(.caption2)
                }

                // MARK: - Lossless Snapshot
                Section("画面截图") {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            onSnapshotRequested()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "camera.fill")
                                .foregroundColor(MivuEdition.primaryTint)
                            Text("保存当前原画截图至系统相册")
                                .foregroundColor(.primary)
                        }
                    }
                }
            }
            .navigationTitle("播放设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
