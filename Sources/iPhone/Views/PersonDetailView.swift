import SwiftUI

/// Detailed personal view for cast and crew members, featuring an immersive cinematic
/// backdrop portrait, biographic profile, metadata badges, external database links
/// (Douban, IMDb, TMDB, Trakt), and a full filmography / works catalog.
public struct PersonDetailView: View {
    @Environment(\.dismiss) private var dismiss

    private let initialPerson: MediaPerson
    private let headers: [String: String]?
    private let serverID: UUID?

    @State private var currentPerson: MediaPerson
    @State private var works: [MediaItem] = []
    @State private var isLoadingDetails = false
    @State private var isLoadingWorks = false
    @State private var isBioExpanded = false
    @State private var selectedFilter = "全部"

    public init(person: MediaPerson, headers: [String: String]? = nil, serverID: UUID? = nil) {
        self.initialPerson = person
        self.headers = headers
        self.serverID = serverID
        _currentPerson = State(initialValue: person)
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // MARK: - 1. Hero Header (Portrait, Ambient Glow, Name & Roles)
                    heroHeaderSection

                    // MARK: - 2. Content Body
                    VStack(alignment: .leading, spacing: 22) {
                        // Quick Metadata Badges Row (Birth, Place, Works count)
                        metadataBadgesRow

                        // Biography / Personal Overview
                        biographySection

                        // External Links (Douban, IMDb, TMDB, Trakt)
                        externalLinksSection

                        // Works / Filmography (所有作品)
                        worksSection
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 60)
                }
            }
            .ignoresSafeArea(edges: .top)

            // MARK: - Floating Top Bar
            floatingTopBar
        }
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .background(NativeInteractivePopGestureEnabler())
        .task {
            await loadPersonDetail()
            await loadPersonWorks()
        }
    }

    // MARK: - Top Floating Bar
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

                // Share person
                ShareLink(
                    item: String.localizedStringWithFormat(String(localized: "%@ - Mivu Cast & Crew"), currentPerson.name),
                    subject: Text(currentPerson.name),
                    message: Text(currentPerson.overview ?? currentPerson.name)
                ) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 3)
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

    // MARK: - 1. Hero Header Section
    private var heroHeaderSection: some View {
        ZStack(alignment: .bottom) {
            // Ambient glow backdrop using person image
            GeometryReader { proxy in
                let minY = proxy.frame(in: .global).minY
                let headerHeight: CGFloat = 380 + (minY > 0 ? minY : 0)

                ZStack {
                    if let imgURL = currentPerson.imageURL {
                        AsyncItemArtwork(url: imgURL, headers: headers)
                            .scaledToFill()
                            .blur(radius: 50)
                            .opacity(0.4)
                    } else {
                        RadialGradient(
                            colors: [Color.orange.opacity(0.25), Color.black],
                            center: .center,
                            startRadius: 20,
                            endRadius: 240
                        )
                    }
                }
                .frame(width: proxy.size.width, height: headerHeight)
                .clipped()
                .offset(y: minY > 0 ? -minY : 0)
            }
            .frame(height: 380)

            // Multi-stop gradient overlay transitioning into pure black
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.1), location: 0.0),
                    .init(color: .black.opacity(0.5), location: 0.5),
                    .init(color: .black.opacity(0.85), location: 0.8),
                    .init(color: .black, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 380)

            // Portrait Card, Name, Role
            VStack(spacing: 12) {
                // Portrait photo
                ZStack {
                    Color.white.opacity(0.08)

                    if let imgURL = currentPerson.imageURL {
                        AsyncItemArtwork(url: imgURL, headers: headers)
                            .scaledToFill()
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "person.fill")
                                .font(.system(size: 48))
                                .foregroundColor(.white.opacity(0.35))
                        }
                    }
                }
                .frame(width: 126, height: 168)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.7), radius: 16, x: 0, y: 8)

                // Name
                Text(currentPerson.name)
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.8), radius: 6, x: 0, y: 3)
                    .padding(.horizontal, 20)

                // Primary role or department badge
                HStack(spacing: 8) {
                    if let role = currentPerson.role, !role.isEmpty {
                        Text(role)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.15))
                            .clipShape(Capsule())
                    }

                    if let type = currentPerson.type, !type.isEmpty {
                        Text(translatePersonType(type))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    // MARK: - 2. Quick Metadata Badges Row
    private var metadataBadgesRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                // Works count
                HStack(spacing: 5) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    Text(String.localizedStringWithFormat(String(localized: "%d Works"), works.count))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())

                // Birth Date & Age
                if let birthDate = currentPerson.birthDate, !birthDate.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "calendar")
                            .font(.system(size: 12))
                            .foregroundColor(.cyan)
                        Text(formatBirthDate(birthDate))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
                }

                // Birth Place
                if let birthPlace = currentPerson.birthPlace, !birthPlace.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                        Text(birthPlace)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - 3. Biography / Personal Overview
    private var biographySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("个人介绍")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)

            if let overview = currentPerson.overview, !overview.isEmpty {
                Text(overview)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.white.opacity(0.85))
                    .lineSpacing(4)
                    .lineLimit(isBioExpanded ? nil : 4)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isBioExpanded.toggle()
                    }
                } label: {
                    Text(isBioExpanded ? String(localized: "收起") : String(localized: "展开全文"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.orange)
                }
            } else {
                Text("暂无该演职人员的详细介绍")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.vertical, 4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if currentPerson.overview != nil {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isBioExpanded.toggle()
                }
            }
        }
    }

    // MARK: - 4. External Database Links (豆瓣, IMDb, TMDB, Trakt)
    private var externalLinksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("外部数据库")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    externalLinkPill(title: "豆瓣", icon: "link") {
                        if let doubanId = currentPerson.providerIds?["Douban"] {
                            openWeb(urlStr: "https://movie.douban.com/celebrity/\(doubanId)/")
                        } else {
                            let encoded = currentPerson.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                            openWeb(urlStr: "https://search.douban.com/movie/subject_search?search_text=\(encoded)")
                        }
                    }

                    externalLinkPill(title: "IMDb", icon: "link") {
                        if let imdbId = currentPerson.providerIds?["Imdb"] {
                            openWeb(urlStr: "https://www.imdb.com/name/\(imdbId)/")
                        } else {
                            let encoded = currentPerson.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                            openWeb(urlStr: "https://www.imdb.com/find?q=\(encoded)")
                        }
                    }

                    externalLinkPill(title: "TheMovieDb", icon: "link") {
                        if let tmdbId = currentPerson.providerIds?["Tmdb"] {
                            openWeb(urlStr: "https://www.themoviedb.org/person/\(tmdbId)")
                        } else {
                            let encoded = currentPerson.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                            openWeb(urlStr: "https://www.themoviedb.org/search/person?query=\(encoded)")
                        }
                    }

                    externalLinkPill(title: "Trakt", icon: "link") {
                        let encoded = currentPerson.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        openWeb(urlStr: "https://trakt.tv/search/people?query=\(encoded)")
                    }
                }
            }
        }
    }

    private func externalLinkPill(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                Text(String(localized: title))
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
    }

    // MARK: - 5. Works / Filmography Section (所有作品)
    private var worksSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("参与作品")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)

                Text("(\(works.count))")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))

                Spacer()
            }

            // Role filter tabs if multiple categories exist
            if filterOptions.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(filterOptions, id: \.self) { filter in
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedFilter = filter
                                }
                            } label: {
                Text(String(localized: filter))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(selectedFilter == filter ? .white : .white.opacity(0.6))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(selectedFilter == filter ? Color.orange : Color.white.opacity(0.08))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }

            // Works Grid or Empty state
            if isLoadingWorks {
                HStack {
                    Spacer()
                    ProgressView()
                        .tint(.orange)
                        .padding(.vertical, 24)
                    Spacer()
                }
            } else if filteredWorks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "film")
                        .font(.system(size: 32))
                        .foregroundColor(.white.opacity(0.3))
                    Text("暂无相关作品收录")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(Color.white.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ], spacing: 16) {
                    ForEach(filteredWorks) { item in
                        NavigationLink {
                            VideoDetailView(item: item)
                        } label: {
                            workCard(for: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func workCard(for item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                // Poster image
                ZStack {
                    Color.white.opacity(0.08)
                    if let poster = item.posterUrl {
                        AsyncItemArtwork(url: poster, headers: item.headers ?? headers)
                            .scaledToFill()
                    } else if let backdrop = item.backdropUrl {
                        AsyncItemArtwork(url: backdrop, headers: item.headers ?? headers)
                            .scaledToFill()
                    } else {
                        Image(systemName: "film")
                            .font(.title3)
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
                .aspectRatio(2/3, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                // Rating Badge
                if let rating = item.rating, rating > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.yellow)
                        Text(String(format: "%.1f", rating))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // Title, Year, Person's Role
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if let year = item.year {
                        Text("\(year)")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.6))
                    }

                    // Role in this specific work
                    if let matchedPerson = item.people?.first(where: { $0.id == currentPerson.id || $0.name == currentPerson.name }),
                       let role = matchedPerson.role, !role.isEmpty {
                        Text("• \(role)")
                            .font(.system(size: 10))
                            .foregroundColor(.orange.opacity(0.85))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: - Filters
    private var filterOptions: [String] {
        var options = ["全部"]
        let hasDirector = works.contains { item in
            item.people?.contains { p in
                (p.id == currentPerson.id || p.name == currentPerson.name) &&
                ((p.type?.lowercased() == "director") || (p.role?.contains("导演") == true))
            } == true
        }
        if hasDirector { options.append("导演") }

        let hasActor = works.contains { item in
            item.people?.contains { p in
                (p.id == currentPerson.id || p.name == currentPerson.name) &&
                ((p.type?.lowercased() == "actor") || (p.role?.contains("配音") == true) || (p.role?.contains("饰") == true))
            } == true
        }
        if hasActor { options.append("演员") }

        let hasWriter = works.contains { item in
            item.people?.contains { p in
                (p.id == currentPerson.id || p.name == currentPerson.name) &&
                ((p.type?.lowercased() == "writer") || (p.role?.contains("编剧") == true))
            } == true
        }
        if hasWriter { options.append("编剧") }

        let hasProducer = works.contains { item in
            item.people?.contains { p in
                (p.id == currentPerson.id || p.name == currentPerson.name) &&
                ((p.type?.lowercased() == "producer") || (p.role?.contains("制片") == true))
            } == true
        }
        if hasProducer { options.append("制片") }

        return options
    }

    private var filteredWorks: [MediaItem] {
        if selectedFilter == "全部" {
            return works
        }
        return works.filter { item in
            guard let matched = item.people?.first(where: { $0.id == currentPerson.id || $0.name == currentPerson.name }) else {
                return false
            }
            switch selectedFilter {
            case "导演":
                return (matched.type?.lowercased() == "director") || (matched.role?.contains("导演") == true)
            case "演员":
                return (matched.type?.lowercased() == "actor") || (matched.role?.contains("配音") == true) || (matched.role?.contains("饰") == true)
            case "编剧":
                return (matched.type?.lowercased() == "writer") || (matched.role?.contains("编剧") == true)
            case "制片":
                return (matched.type?.lowercased() == "producer") || (matched.role?.contains("制片") == true)
            default:
                return true
            }
        }
    }

    // MARK: - Data Loading
    private func loadPersonDetail() async {
        isLoadingDetails = true
        defer { isLoadingDetails = false }

        // 1. Try fetching rich details from media server (Emby / Jellyfin)
        if let serverID, let client = MediaServerManager.shared.getClient(for: serverID) {
            if let detail = try? await client.fetchPersonDetail(personId: currentPerson.id) {
                await MainActor.run {
                    var merged = detail
                    if merged.role == nil { merged = MediaPerson(
                        id: detail.id,
                        name: detail.name,
                        role: currentPerson.role,
                        type: detail.type ?? currentPerson.type,
                        imageURL: detail.imageURL ?? currentPerson.imageURL,
                        overview: detail.overview ?? currentPerson.overview,
                        birthDate: detail.birthDate ?? currentPerson.birthDate,
                        deathDate: detail.deathDate ?? currentPerson.deathDate,
                        birthPlace: detail.birthPlace ?? currentPerson.birthPlace,
                        providerIds: detail.providerIds ?? currentPerson.providerIds
                    ) }
                    self.currentPerson = merged
                }
            }
        }

        // 2. Built-in biographies for sample/known artists if still missing overview
        if currentPerson.overview == nil || currentPerson.overview?.isEmpty == true {
            let fallbackInfo = builtInPersonInfo(for: currentPerson.name)
            if let fallbackInfo {
                await MainActor.run {
                    var updated = self.currentPerson
                    if updated.overview == nil { updated.overview = fallbackInfo.overview }
                    if updated.birthDate == nil { updated.birthDate = fallbackInfo.birthDate }
                    if updated.birthPlace == nil { updated.birthPlace = fallbackInfo.birthPlace }
                    self.currentPerson = updated
                }
            }
        }
    }

    private func loadPersonWorks() async {
        isLoadingWorks = true
        defer { isLoadingWorks = false }

        var collected: [MediaItem] = []

        // 1. Fetch from media server if connected
        if let serverID, let client = MediaServerManager.shared.getClient(for: serverID) {
            if let serverWorks = try? await client.fetchPersonWorks(personId: currentPerson.id, personName: currentPerson.name),
               !serverWorks.isEmpty {
                collected.append(contentsOf: serverWorks)
            }
        }

        // 2. Find matching items from local Playback History and Sample Streams
        let localPool = PlaybackHistory.shared.items + MediaItem.sampleStreams
        for item in localPool {
            if item.people?.contains(where: { $0.id == currentPerson.id || $0.name == currentPerson.name }) == true {
                if !collected.contains(where: { $0.id == item.id || $0.title == item.title }) {
                    collected.append(item)
                }
            }
        }

        await MainActor.run {
            self.works = collected
        }
    }

    // MARK: - Helpers
    private func translatePersonType(_ type: String) -> String {
        switch type.lowercased() {
        case "actor": return String(localized: "演员")
        case "director": return String(localized: "导演")
        case "writer": return String(localized: "编剧")
        case "producer": return String(localized: "制片")
        case "composer": return String(localized: "配乐")
        case "cinematographer": return String(localized: "摄影")
        case "editor": return String(localized: "剪辑")
        default: return type
        }
    }

    private func formatBirthDate(_ dateStr: String) -> String {
        // e.g. "1970-07-30T00:00:00.0000000Z" or "1970-07-30"
        let prefix = String(dateStr.prefix(10))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: prefix) {
            let age = Calendar.current.dateComponents([.year], from: date, to: Date()).year ?? 0
            if age > 0 {
                return String.localizedStringWithFormat(String(localized: "%@ (%d years old)"), prefix, age)
            }
        }
        return prefix
    }

    private func openWeb(urlStr: String) {
        guard let url = URL(string: urlStr) else { return }
        UIApplication.shared.open(url)
    }

    private func builtInPersonInfo(for name: String) -> (overview: String, birthDate: String?, birthPlace: String?)? {
        switch name {
        case "Colin Levy":
            return (
                overview: String(localized: "Colin Levy 是美国独立电影导演与视觉特效艺术家，曾就职于皮克斯动画工作室（Pixar Animation Studios），参与制作了多部知名皮克斯长片。作为 Blender 基金会 Durian 开放电影项目核心导演，他执导了享誉全球的开源奇幻动画短片《Sintel》。"),
                birthDate: "1988-12-05",
                birthPlace: String(localized: "美国俄亥俄州")
            )
        case "Halina Reijn":
            return (
                overview: String(localized: "Halina Reijn 是荷兰知名女演员、导演及作家，多次荣获荷兰电影节金牛奖（Golden Calf）。她曾在保罗·范霍文执导的二战惊悚片《黑皮书》中奉献了精湛演技，并在 Blender 基金会的动画短片《Sintel》中为女主角 Sintel 倾情献声配音。"),
                birthDate: "1975-11-10",
                birthPlace: String(localized: "荷兰阿姆斯特丹")
            )
        case "Sacha Goedegebure":
            return (
                overview: String(localized: "Sacha Goedegebure（网名 Saschart）是知名的 3D 动画艺术家与数字插画师，作为核心导演执导了开源 3D 动画电影《大白兔》（Big Buck Bunny），在开源艺术与计算机图形学领域享有盛誉。"),
                birthDate: "1978-04-10",
                birthPlace: String(localized: "荷兰")
            )
        case "Ton Roosendaal":
            return (
                overview: String(localized: "Ton Roosendaal 是荷兰著名软件开发者与电影制片人，Blender 开源 3D 创作套件的首席创作者，Blender 基金会创始人兼主席。他主导了《Elephants Dream》、《大白兔》、《Sintel》等一系列开源电影项目，推动了全球开放电影与开源 CG 技术的蓬勃发展。"),
                birthDate: "1960-03-20",
                birthPlace: String(localized: "荷兰海尔德兰省")
            )
        default:
            return nil
        }
    }
}
