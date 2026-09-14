import SwiftUI
import AVFoundation

/// Video detail view inspired by VidHub / Infuse, featuring a cinematic backdrop hero,
/// rich metadata badges, quick actions bar, cast and crew carousel, similar titles,
/// external database links (Douban, IMDb, TMDB, Trakt), and deep media stream inspection.
public struct VideoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var playerService = PlayerService.shared

    @State private var currentItem: MediaItem
    @State private var similarItems: [MediaItem] = []
    @State private var isOverviewExpanded = false
    @State private var isResolvingPlayback = false
    @State private var isShowingPlayer = false
    @State private var errorMessage: String?
    @State private var isShowingErrorAlert = false
    @State private var isLoadingUnifiedRatings = true

    // Action sheets & drawers
    @State private var isShowingAudioSheet = false
    @State private var isShowingSubtitleSheet = false
    @State private var isShowingVersionsSheet = false

    public init(item: MediaItem) {
        _currentItem = State(initialValue: item)
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // MARK: - 1. Cinematic Backdrop & Title Overlay
                    backdropHeroHeader

                    // MARK: - 2. Content Body
                    VStack(alignment: .leading, spacing: 22) {
                        // Playback CTA Button & Action Bar
                        playbackControlsSection

                        // Plot Synopsis / Overview
                        if let overview = currentItem.overview, !overview.isEmpty {
                            overviewSection(overview)
                        }

                        // Cast & Crew Carousel (演职人员)
                        if let people = currentItem.people, !people.isEmpty {
                            castAndCrewSection(people)
                        }

                        // Similar Titles (类似作品)
                        if !similarItems.isEmpty {
                            similarWorksSection
                        }

                        // Media Technical Specs Cards (媒体信息: 视频, 音频)
                        mediaInfoSection

                        // Technical Metadata & Footer Release Info
                        footerReleaseSection
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 60)
                }
            }
            .ignoresSafeArea(edges: .top)

            // MARK: - Floating Top Bar Buttons (Back, Search, More)
            floatingTopBar
        }
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .background(NativeInteractivePopGestureEnabler())
        .task {
            async let similar: Void = loadSimilarItems()
            async let mediaInspection: Void = inspectMediaIfNeeded()
            await loadRichDetails()
            await loadUnifiedRatings()
            await similar
            await mediaInspection
        }
        .fullScreenCover(isPresented: $isShowingPlayer) {
            PlayerView()
        }
        .sheet(isPresented: $isShowingAudioSheet) {
            audioTracksSheet
        }
        .sheet(isPresented: $isShowingSubtitleSheet) {
            subtitleTracksSheet
        }
        .sheet(isPresented: $isShowingVersionsSheet) {
            versionsSheet
        }
        .alert("播放错误", isPresented: $isShowingErrorAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "无法解析该媒体流")
        }
    }

    // MARK: - Top Floating Bar (Back, Search, More)
    private var floatingTopBar: some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 3)
                }

                Spacer()

                HStack(spacing: 12) {
                    Menu {
                        Button {
                            UIPasteboard.general.string = currentItem.url.absoluteString
                        } label: {
                            Label("复制流地址", systemImage: "doc.on.doc")
                        }

                        Button {
                            Task {
                                await loadRichDetails()
                                await loadUnifiedRatings()
                                await inspectMediaIfNeeded()
                            }
                        } label: {
                            Label("刷新媒体信息", systemImage: "arrow.clockwise")
                        }

                        Button {
                            togglePlayed()
                        } label: {
                            Label(currentItem.isPlayed == true ? "标记为未看" : "标记为已看", systemImage: currentItem.isPlayed == true ? "eye.slash" : "checkmark.circle")
                        }

                        Button {
                            toggleFavorite()
                        } label: {
                            Label(currentItem.isFavorite == true ? "取消收藏" : "加入收藏", systemImage: currentItem.isFavorite == true ? "heart.slash" : "heart")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 3)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, safeAreaTopInset + 6)

            Spacer()
        }
        .ignoresSafeArea(edges: .top)
    }

    private var safeAreaTopInset: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first?.safeAreaInsets.top ?? 44
    }

    // MARK: - 1. Backdrop Hero Header
    private var backdropHeroHeader: some View {
        ZStack(alignment: .bottom) {
            // Backdrop image or blur poster
            GeometryReader { proxy in
                let minY = proxy.frame(in: .global).minY
                let headerHeight: CGFloat = 430 + (minY > 0 ? minY : 0)

                Group {
                    if let backdrop = currentItem.backdropUrl {
                        AsyncItemArtwork(url: backdrop, headers: currentItem.headers)
                    } else if let poster = currentItem.posterUrl {
                        AsyncItemArtwork(url: poster, headers: currentItem.headers)
                    } else {
                        fallbackBackdrop
                    }
                }
                .scaledToFill()
                .frame(width: proxy.size.width, height: headerHeight)
                .clipped()
                .offset(y: minY > 0 ? -minY : 0)
            }
            .frame(height: 430)

            // Deep multi-stop gradient overlay transitioning smoothly to pure black
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black.opacity(0.2), location: 0.35),
                    .init(color: .black.opacity(0.65), location: 0.65),
                    .init(color: .black.opacity(0.92), location: 0.88),
                    .init(color: .black, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 430)

            // Title, Logo, Badges & Metadata
            VStack(spacing: 8) {
                // Movie Logo or Big Stylized Title
                if let logo = currentItem.logoUrl {
                    AsyncItemArtwork(url: logo, headers: currentItem.headers)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 260, maxHeight: 75)
                        .shadow(color: .black.opacity(0.8), radius: 8, x: 0, y: 4)
                        .padding(.bottom, 2)
                } else {
                    Text(currentItem.title)
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.8), radius: 6, x: 0, y: 3)
                        .padding(.horizontal, 20)
                }

                // Rating Badges & Content Rating Badge
                HStack(spacing: 8) {
                    if let imdb = currentItem.effectiveImdbRating, imdb > 0 {
                        HStack(spacing: 3) {
                            Text("IMDb")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundColor(.black)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color(red: 0.96, green: 0.77, blue: 0.19))
                                .clipShape(RoundedRectangle(cornerRadius: 2.5))
                            Text(String(format: "%.1f", imdb))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }

                    if let douban = currentItem.effectiveDoubanRating, douban > 0 {
                        HStack(spacing: 3) {
                            Text("豆")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color(red: 0.22, green: 0.82, blue: 0.38))
                                .clipShape(RoundedRectangle(cornerRadius: 2.5))
                            Text(String(format: "%.1f", douban))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }

                    if let rt = currentItem.effectiveRottenTomatoesRating, rt > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: rt >= 60 ? "flame.fill" : "cross.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(rt >= 60 ? Color(red: 0.98, green: 0.22, blue: 0.16) : Color(red: 0.45, green: 0.75, blue: 0.25))
                            Text("\(Int(rt))%")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }

                    if let contentRating = currentItem.contentRating, !contentRating.isEmpty {
                        Text(contentRating)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.white.opacity(0.7), lineWidth: 1)
                            )
                    }
                }

                // Formatted technical metadata summary row
                HStack(spacing: 8) {
                    if let duration = currentItem.duration, duration > 0 {
                        Text(formatDuration(duration))
                    }

                    if let release = currentItem.releaseDate, !release.isEmpty {
                        Text(release)
                    } else if let year = currentItem.year {
                        Text("\(year)")
                    }

                    if let res = resolutionString {
                        Text(res)
                    }

                    if let dynamicRange = currentItem.videoStreamInfo?.dynamicRange, !dynamicRange.isEmpty {
                        Text(dynamicRange.uppercased())
                    }

                    if let fps = currentItem.videoStreamInfo?.frameRate, fps > 0 {
                        Text("\(Int(round(fps)))FPS")
                    }

                    if let size = currentItem.fileSize, size > 0 {
                        Text(formatFileSize(size))
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)

                // Genres list
                if let genres = currentItem.genres, !genres.isEmpty {
                    Text(genres.joined(separator: "，"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))
                }
            }
            .padding(.bottom, 12)
        }
    }

    private var fallbackBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [Color.orange.opacity(0.35), Color.purple.opacity(0.25), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "film")
                .font(.system(size: 60))
                .foregroundColor(.white.opacity(0.12))
        }
    }

    // MARK: - 2. Playback CTA & Action Bar
    private var playbackControlsSection: some View {
        VStack(spacing: 16) {
            // Big Primary Play Button
            HStack(spacing: 10) {
                Button {
                    startPlayback(fromBeginning: false)
                } label: {
                    HStack(spacing: 8) {
                        if isResolvingPlayback {
                            ProgressView()
                                .tint(.black)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 16, weight: .bold))
                            Text(playButtonTitle)
                                .font(.system(size: 16, weight: .bold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color(white: 0.92))
                    .foregroundColor(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(isResolvingPlayback)

                // Dropdown menu for alternative actions
                Menu {
                    if let resume = currentItem.resumePosition, resume > 0 {
                        Button {
                            startPlayback(fromBeginning: true)
                        } label: {
                            Label("从头开始播放", systemImage: "arrow.counterclockwise")
                        }
                    }

                    if let alts = currentItem.playbackAlternatives, !alts.isEmpty {
                        Button {
                            isShowingVersionsSheet = true
                        } label: {
                            Label("选择播放版本 (\(alts.count + 1))", systemImage: "film.stack")
                        }
                    }

                    Button {
                        isShowingAudioSheet = true
                    } label: {
                        Label("音轨选项", systemImage: "headphones")
                    }

                    Button {
                        isShowingSubtitleSheet = true
                    } label: {
                        Label("字幕选项", systemImage: "captions.bubble")
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 50, height: 50)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }

            // Quick Action Buttons Row (Watched, Favorite, Versions, Audio, Subtitles)
            HStack(spacing: 0) {
                // Watched toggle
                actionCircleButton(
                    icon: currentItem.isPlayed == true ? "checkmark.circle.fill" : "checkmark.circle",
                    tint: currentItem.isPlayed == true ? .orange : .white
                ) {
                    togglePlayed()
                }

                Spacer()

                // Favorite toggle
                actionCircleButton(
                    icon: currentItem.isFavorite == true ? "heart.fill" : "heart",
                    tint: currentItem.isFavorite == true ? .red : .white
                ) {
                    toggleFavorite()
                }

                Spacer()

                // Versions / Sources
                actionCircleButton(icon: "film.stack", tint: .white) {
                    isShowingVersionsSheet = true
                }

                Spacer()

                // Audio tracks
                actionCircleButton(icon: "headphones", tint: .white) {
                    isShowingAudioSheet = true
                }

                Spacer()

                // Subtitle tracks
                actionCircleButton(icon: "captions.bubble", tint: .white) {
                    isShowingSubtitleSheet = true
                }
            }
            .padding(.horizontal, 10)
        }
    }

    private func actionCircleButton(icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(tint)
                .frame(width: 48, height: 48)
                .background(Color.white.opacity(0.12))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var playButtonTitle: String {
        if let resume = currentItem.resumePosition, let duration = currentItem.duration, duration > 0, resume > 0 {
            let pct = Int((resume / duration) * 100)
            return "继续播放 (\(pct)%)"
        }
        return "播放"
    }

    // MARK: - 3. Plot Overview Section
    private func overviewSection(_ overview: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(overview)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.white.opacity(0.85))
                .lineSpacing(4)
                .lineLimit(isOverviewExpanded ? nil : 4)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isOverviewExpanded.toggle()
                }
            } label: {
                Text(isOverviewExpanded ? "收起" : "展开全文")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orange)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isOverviewExpanded.toggle()
            }
        }
    }

    // MARK: - 4. Media Ratings Section (豆瓣, IMDb, 烂番茄)
    private var ratingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("媒体评分")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    // 1. 豆瓣评分
                    if let douban = currentItem.effectiveDoubanRating {
                        doubanRatingCard(score: douban)
                    } else {
                        unavailableRatingCard(name: "豆瓣", tint: Color(red: 0.22, green: 0.82, blue: 0.38))
                    }

                    // 2. IMDb 评分
                    if let imdb = currentItem.effectiveImdbRating {
                        imdbRatingCard(score: imdb)
                    } else {
                        unavailableRatingCard(name: "IMDb", tint: Color(red: 0.96, green: 0.77, blue: 0.19))
                    }

                    // 3. 烂番茄新鲜度 (Rotten Tomatoes)
                    if let rt = currentItem.effectiveRottenTomatoesRating {
                        rottenTomatoesRatingCard(score: rt)
                    } else {
                        unavailableRatingCard(name: "烂番茄", tint: Color(red: 0.98, green: 0.22, blue: 0.16))
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func unavailableRatingCard(name: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tint.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            Text(isLoadingUnifiedRatings ? "正在获取评分" : "暂无评分")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white.opacity(0.82))

            Text(isLoadingUnifiedRatings ? "请稍候" : "暂未收录")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.45))
        }
        .frame(width: 106, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.16), lineWidth: 1)
        )
    }

    private func doubanRatingCard(score: Double) -> some View {
        Button {
            if let doubanId = currentItem.providerIds?["Douban"] {
                openWeb(urlStr: "https://movie.douban.com/subject/\(doubanId)/")
            } else {
                let encoded = currentItem.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                openWeb(urlStr: "https://search.douban.com/movie/subject_search?search_text=\(encoded)")
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("豆瓣")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(red: 0.22, green: 0.82, blue: 0.38))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(red: 0.22, green: 0.82, blue: 0.38).opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                }

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(format: "%.1f", score))
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                    Text("/ 10")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }

                HStack(spacing: 2) {
                    ForEach(0..<5) { idx in
                        let fill = min(max((score / 2.0) - Double(idx), 0), 1)
                        Image(systemName: fill >= 0.75 ? "star.fill" : (fill >= 0.25 ? "star.leadinghalf.filled" : "star"))
                            .font(.system(size: 8))
                            .foregroundColor(Color(red: 0.22, green: 0.82, blue: 0.38))
                    }
                }
            }
            .frame(width: 106, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(red: 0.22, green: 0.82, blue: 0.38).opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .allowsHitTesting(false)
    }

    private var doubanPlaceholderCard: some View {
        Button {
            let encoded = currentItem.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            openWeb(urlStr: "https://search.douban.com/movie/subject_search?search_text=\(encoded)")
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("豆瓣")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(red: 0.22, green: 0.82, blue: 0.38))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(red: 0.22, green: 0.82, blue: 0.38).opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                }

                Text("去豆瓣")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))

                Text("查看影评")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
            }
            .frame(width: 106, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .allowsHitTesting(false)
    }

    private func imdbRatingCard(score: Double) -> some View {
        Button {
            if let imdbId = currentItem.providerIds?["Imdb"] {
                openWeb(urlStr: "https://www.imdb.com/title/\(imdbId)/")
            } else {
                let encoded = currentItem.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                openWeb(urlStr: "https://www.imdb.com/find?q=\(encoded)")
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("IMDb")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundColor(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(red: 0.96, green: 0.77, blue: 0.19))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                }

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(format: "%.1f", score))
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                    Text("/ 10")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }

                HStack(spacing: 2) {
                    ForEach(0..<5) { idx in
                        let fill = min(max((score / 2.0) - Double(idx), 0), 1)
                        Image(systemName: fill >= 0.75 ? "star.fill" : (fill >= 0.25 ? "star.leadinghalf.filled" : "star"))
                            .font(.system(size: 8))
                            .foregroundColor(Color(red: 0.96, green: 0.77, blue: 0.19))
                    }
                }
            }
            .frame(width: 106, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(red: 0.96, green: 0.77, blue: 0.19).opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .allowsHitTesting(false)
    }

    private var imdbPlaceholderCard: some View {
        Button {
            let encoded = currentItem.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            openWeb(urlStr: "https://www.imdb.com/find?q=\(encoded)")
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("IMDb")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundColor(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(red: 0.96, green: 0.77, blue: 0.19))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                    Spacer()

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.35))
                }

                Text("查 IMDb")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))

                Text("全球大众评分")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
            }
            .frame(width: 106, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func rottenTomatoesRatingCard(score: Double) -> some View {
        let isFresh = score >= 60.0
        let tintColor = isFresh ? Color(red: 0.98, green: 0.22, blue: 0.16) : Color(red: 0.45, green: 0.75, blue: 0.25)

        return Button {
            if let imdbId = currentItem.providerIds?["Imdb"] {
                openWeb(urlStr: "https://trakt.tv/search/imdb/\(imdbId)")
            } else {
                let encoded = currentItem.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                openWeb(urlStr: "https://www.rottentomatoes.com/search?search=\(encoded)")
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    HStack(spacing: 3) {
                        Image(systemName: isFresh ? "flame.fill" : "cross.circle.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text(isFresh ? "烂番茄" : "番茄酱")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundColor(tintColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tintColor.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                }

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int(score))%")
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                }

                Text(isFresh ? "新鲜度认证" : "爆米花评价")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
            }
            .frame(width: 106, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(tintColor.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .allowsHitTesting(false)
    }

    private var rottenTomatoesPlaceholderCard: some View {
        Button {
            let encoded = currentItem.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            openWeb(urlStr: "https://www.rottentomatoes.com/search?search=\(encoded)")
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    HStack(spacing: 3) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text("烂番茄")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundColor(Color(red: 0.98, green: 0.22, blue: 0.16))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(red: 0.98, green: 0.22, blue: 0.16).opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                    Spacer()

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.35))
                }

                Text("查新鲜度")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))

                Text("影评人评分")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
            }
            .frame(width: 106, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 5. Cast & Crew Carousel (演职人员)
    private func castAndCrewSection(_ people: [MediaPerson]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("演职人员")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(people) { person in
                        NavigationLink {
                            PersonDetailView(
                                person: person,
                                headers: currentItem.headers,
                                serverID: currentItem.serverID
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack {
                                    Color.white.opacity(0.08)
                                    if let imgURL = person.imageURL {
                                        AsyncItemArtwork(url: imgURL, headers: currentItem.headers)
                                            .scaledToFill()
                                    } else {
                                        Image(systemName: "person.fill")
                                            .font(.title2)
                                            .foregroundColor(.white.opacity(0.3))
                                    }
                                }
                                .frame(width: 72, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(person.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.white)
                                        .lineLimit(1)

                                    if let role = person.role, !role.isEmpty {
                                        Text(role)
                                            .font(.system(size: 10))
                                            .foregroundColor(.white.opacity(0.6))
                                            .lineLimit(1)
                                    }

                                    if let type = person.type, !type.isEmpty {
                                        Text(translatePersonType(type))
                                            .font(.system(size: 9))
                                            .foregroundColor(.white.opacity(0.4))
                                    }
                                }
                                .frame(width: 72, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - 6. Similar Works Carousel (类似作品)
    private var similarWorksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("类似作品")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(similarItems) { similar in
                        NavigationLink {
                            VideoDetailView(item: similar)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack(alignment: .bottomTrailing) {
                                    if let poster = similar.posterUrl {
                                        AsyncItemArtwork(url: poster, headers: similar.headers)
                                            .scaledToFill()
                                    } else {
                                        Color.white.opacity(0.08)
                                        Image(systemName: "film")
                                            .foregroundColor(.white.opacity(0.3))
                                    }

                                    if let rating = similar.rating, rating > 0 {
                                        Text(String(format: "%.1f", rating))
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(Color.black.opacity(0.75))
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                            .padding(4)
                                    }
                                }
                                .frame(width: 110, height: 165)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(similar.title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.white)
                                        .lineLimit(1)

                                    if let year = similar.year {
                                        Text("\(year)")
                                            .font(.system(size: 11))
                                            .foregroundColor(.white.opacity(0.6))
                                    }
                                }
                                .frame(width: 110, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - 7. External Database Links (链接)
    private var externalLinksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("链接")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    externalLinkPill(title: "豆瓣", icon: "link") {
                        if let doubanId = currentItem.providerIds?["Douban"] {
                            openWeb(urlStr: "https://movie.douban.com/subject/\(doubanId)/")
                        } else {
                            let encoded = currentItem.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                            openWeb(urlStr: "https://search.douban.com/movie/subject_search?search_text=\(encoded)")
                        }
                    }

                    externalLinkPill(title: "IMDb", icon: "link") {
                        if let imdbId = currentItem.providerIds?["Imdb"] {
                            openWeb(urlStr: "https://www.imdb.com/title/\(imdbId)/")
                        } else {
                            let encoded = currentItem.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                            openWeb(urlStr: "https://www.imdb.com/find?q=\(encoded)")
                        }
                    }

                    externalLinkPill(title: "TheMovieDb", icon: "link") {
                        if let tmdbId = currentItem.providerIds?["Tmdb"] {
                            openWeb(urlStr: "https://www.themoviedb.org/movie/\(tmdbId)")
                        } else {
                            let encoded = currentItem.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                            openWeb(urlStr: "https://www.themoviedb.org/search?query=\(encoded)")
                        }
                    }

                    externalLinkPill(title: "Trakt", icon: "link") {
                        if let traktId = currentItem.providerIds?["Trakt"] {
                            openWeb(urlStr: "https://trakt.tv/movies/\(traktId)")
                        } else {
                            let encoded = currentItem.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                            openWeb(urlStr: "https://trakt.tv/search?query=\(encoded)")
                        }
                    }
                }
            }
        }
    }

    private func externalLinkPill(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(.white.opacity(0.9))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.09))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 8. Media Information (媒体信息: 视频, 音频)
    private var mediaInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("媒体信息")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    // Video Card
                    videoInfoCard

                    // Audio Card(s)
                    if let audios = currentItem.audioStreamInfo, !audios.isEmpty {
                        ForEach(audios) { audio in
                            audioInfoCard(audio)
                        }
                    } else {
                        audioInfoCard(AudioStreamInfo(id: "default", title: "音频", isDefault: true))
                    }
                }
            }
        }
    }

    private var videoInfoCard: some View {
        let v = currentItem.videoStreamInfo
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "video")
                    .foregroundColor(.orange)
                Text("视频")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
            }
            .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 6) {
                infoRow(key: "标题", val: v?.title ?? resolutionString ?? "自适应流")
                infoRow(key: "编码", val: v?.codec ?? currentItem.videoCodecHint ?? "h264")
                if let w = v?.width, let h = v?.height {
                    infoRow(key: "分辨率", val: "\(w)x\(h)")
                }
                if let fps = v?.frameRate {
                    infoRow(key: "帧率", val: String(format: "%.3f", fps))
                }
                if let bitRate = v?.bitRate ?? currentItem.bitrate {
                    infoRow(key: "比特率", val: "\(bitRate / 1000) kbps")
                }
                infoRow(key: "动态范围", val: v?.dynamicRange ?? "SDR")
                if let prof = v?.profile { infoRow(key: "配置", val: prof) }
                if let lvl = v?.level { infoRow(key: "等级", val: String(format: "%.1f", lvl)) }
                if let aspect = v?.aspectRatio { infoRow(key: "长宽比", val: aspect) }
                if let interlaced = v?.isInterlaced { infoRow(key: "交错", val: interlaced ? "是" : "否") }
                if let primaries = v?.colorPrimaries { infoRow(key: "基色", val: primaries) }
                if let space = v?.colorSpace { infoRow(key: "色域", val: space) }
                if let transfer = v?.colorTransfer { infoRow(key: "色偏", val: transfer) }
                if let depth = v?.bitDepth { infoRow(key: "位深", val: "\(depth)") }
                if let pix = v?.pixelFormat { infoRow(key: "像素格式", val: pix) }
            }
        }
        .padding(16)
        .frame(width: 250, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func audioInfoCard(_ a: AudioStreamInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2")
                    .foregroundColor(.orange)
                Text("音频")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                if a.isDefault {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.orange)
                }
            }
            .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 6) {
                infoRow(key: "标题", val: a.displayTitle ?? a.title ?? "默认音轨")
                if let title = a.title { infoRow(key: "内嵌标题", val: title) }
                if let lang = a.language { infoRow(key: "语言", val: lang) }
                if let layout = a.channelLayout { infoRow(key: "布局", val: layout) }
                if let channels = a.channels { infoRow(key: "声道", val: "\(channels)") }
                if let codec = a.codec { infoRow(key: "编码", val: codec) }
                if let bitRate = a.bitRate { infoRow(key: "比特率", val: "\(bitRate / 1000) kbps") }
                if let sampleRate = a.sampleRate { infoRow(key: "采样率", val: "\(sampleRate) Hz") }
                infoRow(key: "外部", val: a.isExternal ? "是" : "否")
                infoRow(key: "默认", val: a.isDefault ? "是" : "否")
            }
        }
        .padding(16)
        .frame(width: 250, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func infoRow(key: String, val: String) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.55))
            Spacer()
            Text(val)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
        }
    }

    // MARK: - 9. Footer & Release Technical Info
    private var footerReleaseSection: some View {
        VStack(spacing: 6) {
            if let studios = currentItem.studios, !studios.isEmpty {
                Text(studios.joined(separator: " · "))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
            }

            if let fileName = currentItem.fileName ?? currentItem.url.lastPathComponent as String?, !fileName.isEmpty {
                Text(fileName)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                if let originator = currentItem.originator {
                    Text("on \(originator)")
                }
                if let size = currentItem.fileSize {
                    Text(formatFileSize(size))
                }
            }
            .font(.system(size: 10))
            .foregroundColor(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
    }

    // MARK: - Sheets
    private var audioTracksSheet: some View {
        NavigationStack {
            List {
                if let streams = currentItem.audioStreamInfo, !streams.isEmpty {
                    ForEach(streams) { stream in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stream.displayTitle ?? stream.title ?? "音轨")
                                    .font(.headline)
                                Text("\(stream.language ?? "未知语言") · \(stream.codec?.uppercased() ?? "AAC") · \(stream.channelLayout ?? "立体声")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if stream.isDefault {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                } else {
                    Text("该视频未检测到多音轨数据。")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("音轨列表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { isShowingAudioSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var subtitleTracksSheet: some View {
        NavigationStack {
            List {
                if let subs = currentItem.subtitleTracks, !subs.isEmpty {
                    ForEach(subs) { sub in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sub.title ?? sub.language ?? "未知字幕")
                                    .font(.headline)
                                Text("格式: \(sub.format.rawValue.uppercased()) · \(sub.isEmbedded ? "内嵌" : "外挂")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if sub.isDefault {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                } else {
                    Text("该视频暂无字幕轨道。")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("字幕轨道")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { isShowingSubtitleSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var versionsSheet: some View {
        NavigationStack {
            List {
                Section("当前主版本") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(currentItem.title)
                            .font(.headline)
                        Text("格式: \(currentItem.containerHint?.uppercased() ?? "MP4") · 编码: \(currentItem.videoCodecHint?.uppercased() ?? "H264")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if let alts = currentItem.playbackAlternatives, !alts.isEmpty {
                    Section("备选流 / 转码版本") {
                        ForEach(Array(alts.enumerated()), id: \.offset) { index, alt in
                            Button {
                                var copy = currentItem
                                copy.url = alt.url
                                copy.containerHint = alt.containerHint
                                copy.videoCodecHint = alt.videoCodecHint
                                copy.playSessionID = alt.playSessionID
                                copy.mediaSourceID = alt.mediaSourceID
                                currentItem = copy
                                isShowingVersionsSheet = false
                                startPlayback(fromBeginning: false)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("版本 #\(index + 2)")
                                        .font(.subheadline.bold())
                                        .foregroundColor(.primary)
                                    Text("容器: \(alt.containerHint?.uppercased() ?? "HLS/TS") · 编码: \(alt.videoCodecHint?.uppercased() ?? "H264")")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择播放版本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { isShowingVersionsSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Playback Handling
    private func startPlayback(fromBeginning: Bool) {
        if fromBeginning {
            currentItem.resumePosition = 0
        }

        guard currentItem.sourceType == .personalMedia,
              let serverID = currentItem.serverID,
              let client = MediaServerManager.shared.getClient(for: serverID) else {
            playerService.loadAndPlay(item: currentItem)
            isShowingPlayer = true
            return
        }

        isResolvingPlayback = true
        Task {
            do {
                let resolved = try await client.resolvePlaybackItem(currentItem)
                await MainActor.run {
                    isResolvingPlayback = false
                    playerService.loadAndPlay(item: resolved)
                    isShowingPlayer = true
                }
            } catch {
                await MainActor.run {
                    isResolvingPlayback = false
                    errorMessage = error.localizedDescription
                    isShowingErrorAlert = true
                }
            }
        }
    }

    // MARK: - Metadata & Networking
    private func loadRichDetails() async {
        guard currentItem.sourceType == .personalMedia,
              let serverID = currentItem.serverID,
              let itemID = currentItem.serverItemID,
              let client = MediaServerManager.shared.getClient(for: serverID) else { return }

        if let detail = try? await client.fetchItemDetail(itemId: itemID) {
            await MainActor.run {
                self.currentItem = detail
            }
        }
    }

    private func loadUnifiedRatings() async {
        await MainActor.run {
            self.isLoadingUnifiedRatings = true
        }
        let enriched = await UnifiedRatingsAPIClient.enrich(currentItem)
        await MainActor.run {
            if let enriched {
                self.currentItem = enriched
            }
            self.isLoadingUnifiedRatings = false
        }
    }

    private func loadSimilarItems() async {
        guard currentItem.sourceType == .personalMedia,
              let serverID = currentItem.serverID,
              let itemID = currentItem.serverItemID,
              let client = MediaServerManager.shared.getClient(for: serverID) else { return }

        if let similar = try? await client.fetchSimilarItems(itemId: itemID, limit: 10) {
            await MainActor.run {
                self.similarItems = similar
            }
        }
    }

    private func togglePlayed() {
        let next = !(currentItem.isPlayed == true)
        currentItem.isPlayed = next

        if next {
            currentItem.resumePosition = currentItem.duration
        } else {
            currentItem.resumePosition = 0
        }

        guard currentItem.sourceType == .personalMedia,
              let serverID = currentItem.serverID,
              let itemID = currentItem.serverItemID,
              let client = MediaServerManager.shared.getClient(for: serverID) else { return }

        Task {
            try? await client.markPlayed(itemId: itemID, isPlayed: next)
        }
    }

    private func toggleFavorite() {
        let next = !(currentItem.isFavorite == true)
        currentItem.isFavorite = next

        guard currentItem.sourceType == .personalMedia,
              let serverID = currentItem.serverID,
              let itemID = currentItem.serverItemID,
              let client = MediaServerManager.shared.getClient(for: serverID) else { return }

        Task {
            try? await client.toggleFavorite(itemId: itemID, isFavorite: next)
        }
    }

    private func inspectMediaIfNeeded() async {
        guard currentItem.videoStreamInfo == nil else { return }

        let asset = AVURLAsset(url: currentItem.url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let videoTrack = tracks.first else { return }

        let size = (try? await videoTrack.load(.naturalSize)) ?? .zero
        let frameRate = Double((try? await videoTrack.load(.nominalFrameRate)) ?? 0)
        let bitRate = Int((try? await videoTrack.load(.estimatedDataRate)) ?? 0)

        var audioList: [AudioStreamInfo] = []
        if let audioTracks = try? await asset.loadTracks(withMediaType: .audio) {
            for (index, track) in audioTracks.enumerated() {
                let lang = try? await track.load(.extendedLanguageTag)
                audioList.append(AudioStreamInfo(id: "\(index)", title: lang ?? "Audio \(index + 1)", language: lang, isDefault: index == 0))
            }
        }

        let resolution = size.height >= 2160 ? "4K" : (size.height >= 1080 ? "1080P" : "720P")

        await MainActor.run {
            self.currentItem.videoStreamInfo = VideoStreamInfo(
                title: resolution,
                codec: currentItem.videoCodecHint ?? "h264",
                width: Int(size.width),
                height: Int(size.height),
                frameRate: frameRate > 0 ? frameRate : nil,
                bitRate: bitRate > 0 ? bitRate : nil,
                dynamicRange: "SDR"
            )
            if !audioList.isEmpty {
                self.currentItem.audioStreamInfo = audioList
            }
        }
    }

    // MARK: - Helpers
    private var resolutionString: String? {
        if let w = currentItem.videoStreamInfo?.width, let h = currentItem.videoStreamInfo?.height {
            if h >= 2160 || w >= 3840 { return "4K" }
            if h >= 1080 || w >= 1920 { return "1080P" }
            if h >= 720 { return "720P" }
            return "\(h)P"
        }
        return nil
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let hrs = Int(seconds) / 3600
        let mins = (Int(seconds) % 3600) / 60
        if hrs > 0 {
            return "\(hrs)小时 \(mins)分钟"
        } else {
            return "\(mins)分钟"
        }
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 {
            return String(format: "%.2fG", gb)
        }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0fM", mb)
    }

    private func translatePersonType(_ type: String) -> String {
        switch type.lowercased() {
        case "actor": return "演员"
        case "director": return "导演"
        case "writer": return "编剧"
        case "producer": return "制片"
        default: return type
        }
    }

    private func openWeb(urlStr: String) {
        guard let url = URL(string: urlStr) else { return }
        UIApplication.shared.open(url)
    }
}

/// Restores UIKit's interactive pop gesture when this view supplies its own back control.
struct NativeInteractivePopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        DispatchQueue.main.async {
            guard let navigationController = uiViewController.navigationController else { return }
            navigationController.interactivePopGestureRecognizer?.isEnabled = navigationController.viewControllers.count > 1
        }
    }
}

/// Helper view for asynchronously rendering artwork with authorization headers
struct AsyncItemArtwork: View {
    let url: URL
    let headers: [String: String]?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
            } else {
                Color.white.opacity(0.06)
            }
        }
        .task(id: url) {
            var request = URLRequest(url: url)
            headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let loaded = UIImage(data: data),
                  !Task.isCancelled else { return }
            image = loaded
        }
    }
}
