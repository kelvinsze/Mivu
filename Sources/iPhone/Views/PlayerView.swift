import SwiftUI
import AVKit
import MediaPlayer

/// Video Player View embedding native AVPlayer / MPV surface,
/// frosted-glass overlays, gesture brightness/volume HUD, precision scrubbing,
/// speed selector, subtitle management, aspect ratio toggle, and stream telemetry HUD.
public struct PlayerView: View {
    @ObservedObject var playerService = PlayerService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var isControlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    @State private var showDiagnosticsHUD = false

    // Gestures: Brightness & Volume HUD state
    @State private var brightnessLevel: CGFloat = UIScreen.main.brightness
    @State private var brightnessAtDragStart: CGFloat?
    @State private var showBrightnessHUD = false
    @State private var showVolumeHUD = false
    @State private var hudDismissTask: Task<Void, Never>?

    // Double tap ripple animation feedback
    @State private var seekFeedback: Int? = nil // -15 or +15

    private let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    public init() {}

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                // Video rendering surface (AVPlayer or MPV)
                playbackSurface
                    .ignoresSafeArea(edges: [.top, .bottom])

                // Gesture interaction layer (tap to toggle, double-tap to seek, vertical drag for brightness)
                gestureLayer(geometry: geometry)

                // Error overlay if playback failed
                if playerService.session.status == .failed,
                   let errorMessage = playerService.session.errorMessage {
                    playbackErrorOverlay(errorMessage)
                }

                // On-screen HUD for Brightness
                if showBrightnessHUD {
                    gestureIndicatorHUD(icon: "sun.max.fill", value: brightnessLevel)
                        .transition(.opacity)
                }

                // Seek Ripple Feedback (-15s or +15s)
                if let feedback = seekFeedback {
                    seekRippleView(feedback: feedback)
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

                // Top & Bottom Controls Overlays
                if isControlsVisible {
                    controlsOverlay
                        .transition(.opacity)
                }
            }
        }
        .statusBar(hidden: !isControlsVisible)
        .onAppear {
            if playerService.session.status == .playing {
                scheduleHideControls()
            } else {
                isControlsVisible = true
            }
            brightnessLevel = UIScreen.main.brightness
            if playerService.renderSurfaceKind == .mpvSampleBuffer || playerService.renderSurfaceKind == .mpvOpenGLES {
                playerService.activeMPVEngine?.surfaceViewAppeared()
            }
        }
        .onChange(of: playerService.session.status) { _, newStatus in
            if newStatus == .playing {
                scheduleHideControls()
            } else {
                hideControlsTask?.cancel()
                withAnimation(.easeInOut(duration: 0.2)) {
                    isControlsVisible = true
                }
            }
        }
    }

    // MARK: - Overlays & Surfaces

    @ViewBuilder
    private var playbackSurface: some View {
#if canImport(MPV)
        if (playerService.renderSurfaceKind == .mpvSampleBuffer || playerService.renderSurfaceKind == .mpvOpenGLES),
           let engine = playerService.activeMPVEngine {
            MPVVideoPlayerView(engine: engine)
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

    // MARK: - Gesture Interaction Layer

    private func gestureLayer(geometry: GeometryProxy) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .ignoresSafeArea()
            .onTapGesture(count: 2) { location in
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
                withAnimation(.easeInOut(duration: 0.25)) {
                    isControlsVisible.toggle()
                }
                if isControlsVisible && playerService.session.status == .playing {
                    scheduleHideControls()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 15)
                    .onChanged { value in
                        // Left half vertical drag controls screen brightness
                        if value.startLocation.x < geometry.size.width * 0.4 {
                            let startBrightness = brightnessAtDragStart ?? UIScreen.main.brightness
                            brightnessAtDragStart = startBrightness
                            let delta = -value.translation.height / 300.0
                            let newBrightness = min(max(startBrightness + delta, 0.0), 1.0)
                            UIScreen.main.brightness = newBrightness
                            brightnessLevel = newBrightness
                            showBrightnessHUD = true
                        }
                    }
                    .onEnded { _ in
                        brightnessAtDragStart = nil
                        triggerDismissHUD()
                    }
            )
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
                    .fill(Color.orange)
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
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .orange))
                .scaleEffect(1.3)

            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Text(SOAPParser.formatSpeed(playerService.downloadSpeed))
                        .font(.caption.monospacedDigit().bold())
                        .foregroundColor(.white)
                }

                if playerService.session.duration > 0 {
                    Text("·")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.4))
                    let bufferRatio = min(max(playerService.session.bufferedTime / playerService.session.duration, 0), 1.0)
                    Text("已缓冲 \(Int(bufferRatio * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white.opacity(0.9))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.3), radius: 6)
        }
    }

    private func playbackErrorOverlay(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.orange)
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

    // MARK: - Controls Overlay

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            // MARK: Top Bar
            HStack(spacing: 14) {
                Button {
                    playerService.stop()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3.bold())
                        .foregroundColor(.white)
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(playerService.session.currentItem?.title ?? "正在播放")
                        .font(.headline)
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if let originator = playerService.session.currentItem?.originator {
                        Text(originator)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }

                Spacer()

                // Speed Selector Menu
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
                    Text("\(String(format: "%.1fx", playerService.selectedSpeed))")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }

                // Subtitles Menu
                Menu {
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
                } label: {
                    Image(systemName: playerService.selectedSubtitleTrack == nil ? "captions.bubble" : "captions.bubble.fill")
                        .font(.body)
                        .foregroundColor(playerService.selectedSubtitleTrack == nil ? .white.opacity(0.9) : .orange)
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }

                if playerService.renderSurfaceKind == .nativeAVPlayer {
                    // Aspect ratio toggle
                    Button {
                        playerService.toggleVideoGravity()
                        scheduleHideControls()
                    } label: {
                        Image(systemName: playerService.videoGravity == .resizeAspect ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                            .font(.body)
                            .foregroundColor(.white.opacity(0.9))
                            .padding(8)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                }

                // Diagnostics HUD Toggle
                Button {
                    withAnimation {
                        showDiagnosticsHUD.toggle()
                    }
                    scheduleHideControls()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundColor(showDiagnosticsHUD ? .orange : .white.opacity(0.9))
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }

                if playerService.renderSurfaceKind == .nativeAVPlayer {
                    AirPlayRoutePickerView()
                        .frame(width: 36, height: 36)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .background(
                LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom)
            )

            Spacer()

            // MARK: Center Play/Pause & 15s Jump
            HStack(spacing: 50) {
                Button {
                    playerService.seek(by: -15)
                    scheduleHideControls()
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 34))
                        .foregroundColor(.white)
                }

                Button {
                    playerService.togglePlayPause()
                    scheduleHideControls()
                } label: {
                    Image(systemName: playerService.session.status == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.white)
                        .padding(22)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.3), radius: 10)
                }

                Button {
                    playerService.seek(by: 15)
                    scheduleHideControls()
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 34))
                        .foregroundColor(.white)
                }
            }

            Spacer()

            // MARK: Bottom Scrubber & Time
            VStack(spacing: 10) {
                let currentTime = isScrubbing ? scrubTime : playerService.session.currentTime
                let duration = max(playerService.session.duration, 1)
                let playProgress = min(max(currentTime / duration, 0), 1.0)
                let bufferProgress = min(max(playerService.session.bufferedTime / duration, 0), 1.0)

                // 3-Tier Layered Scrubber: Uncached -> Cached / Buffered -> Played -> Thumb
                GeometryReader { geom in
                    let totalWidth = geom.size.width
                    let trackHeight: CGFloat = isScrubbing ? 7 : 5
                    ZStack(alignment: .leading) {
                        // 1. Uncached background (dark translucent track)
                        Capsule()
                            .fill(Color.white.opacity(0.20))
                            .frame(height: trackHeight)

                        // 2. Cached / Buffered progress track (prominent bright translucent white)
                        Capsule()
                            .fill(Color.white.opacity(0.65))
                            .frame(width: max(0, totalWidth * bufferProgress), height: trackHeight)
                            .animation(.linear(duration: 0.25), value: bufferProgress)

                        // 3. Played progress track (accent color)
                        Capsule()
                            .fill(Color.orange)
                            .frame(width: max(0, totalWidth * playProgress), height: trackHeight)

                        // 4. Scrubbing thumb knob
                        Circle()
                            .fill(Color.white)
                            .frame(width: isScrubbing ? 18 : 13, height: isScrubbing ? 18 : 13)
                            .shadow(color: .black.opacity(0.45), radius: 3)
                            .offset(x: max(0, min(totalWidth * playProgress - (isScrubbing ? 9 : 6.5), totalWidth - (isScrubbing ? 18 : 13))))
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
                .frame(height: 22)

                HStack(alignment: .center) {
                    Text(SOAPParser.formatUPnPTime(currentTime))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white.opacity(0.9))

                    Spacer()

                    // Real-time Buffer & Speed Status
                    if !playerService.session.isLiveStream {
                        HStack(spacing: 6) {
                            if playerService.session.duration > 0 {
                                Text("已缓冲 \(Int(bufferProgress * 100))%")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundColor(.white.opacity(0.7))

                                Text("·")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.4))
                            }

                            HStack(spacing: 3) {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 9, weight: .bold))
                                Text(SOAPParser.formatSpeed(playerService.downloadSpeed))
                                    .font(.caption2.monospacedDigit())
                            }
                            .foregroundColor(.orange.opacity(0.95))
                        }
                    }

                    Spacer()

                    if playerService.session.isLiveStream {
                        HStack(spacing: 4) {
                            Circle().fill(Color.red).frame(width: 6, height: 6)
                            Text("LIVE")
                                .font(.caption.bold())
                                .foregroundColor(.red)
                        }
                    } else {
                        let remaining = max(duration - currentTime, 0)
                        Text("-\(SOAPParser.formatUPnPTime(remaining))")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.white.opacity(0.75))
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
            .padding(.top, 16)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            )
        }
    }

    // MARK: - Diagnostics HUD

    private var diagnosticsHUD: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("STREAM TELEMETRY")
                .font(.caption2.bold())
                .foregroundColor(.orange)

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
                .foregroundColor(.orange)

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
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
        .padding(.leading, 16)
        .padding(.top, 85)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func scheduleHideControls() {
        hideControlsTask?.cancel()
        // 未开始播放（如加载中、已暂停、已停止）时不隐藏播放控制元素
        guard playerService.session.status == .playing else {
            isControlsVisible = true
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

    private func subtitleLabel(_ track: SubtitleTrack) -> String {
        let base = track.title ?? track.language ?? "字幕 \(track.id)"
        let flags = [track.isDefault ? "默认" : nil, track.isForced ? "强制" : nil].compactMap { $0 }
        let capability = track.format == .pgs || track.format == .vobsub ? "图片" : track.format.rawValue.uppercased()
        return flags.isEmpty ? "\(base) · \(capability)" : "\(base)（\(flags.joined(separator: "、"))）· \(capability)"
    }
}

// MARK: - AVPlayer Layer Wrapper

#if canImport(MPV)
public struct MPVVideoPlayerView: UIViewRepresentable {
    public let engine: MPVPlayerEngine

    public init(engine: MPVPlayerEngine) {
        self.engine = engine
    }

    public func makeUIView(context: Context) -> MPVSampleBufferView {
        let view = engine.makeSampleBufferView() ?? MPVSampleBufferView(engine: engine)
        view.isUserInteractionEnabled = false
        return view
    }

    public func updateUIView(_ view: MPVSampleBufferView, context: Context) {
        view.engine = engine
        view.isUserInteractionEnabled = false
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
    }
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
