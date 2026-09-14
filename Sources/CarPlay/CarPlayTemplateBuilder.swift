import Foundation
import CarPlay
import CoreMedia
import OSLog

private let logger = Logger(subsystem: "com.kelvinsze.mivu", category: "CarPlayTemplateBuilder")

/// Builds CPListTemplates and action sheets for CarPlay UI.
@MainActor
public final class CarPlayTemplateBuilder {

    public static func buildRootSections(interfaceController: CPInterfaceController) -> [CPListSection] {
        let session = PlayerService.shared.session
        var sections: [CPListSection] = []

        // MARK: - 1. Now Playing Section
        if let current = session.currentItem {
            let isPlaying = session.status == .playing
            let nowPlayingItem = CPListItem(
                text: current.title,
                detailText: "\(isPlaying ? "▶ 正在播放" : "⏸ 已暂停") · \(SOAPParser.formatUPnPTime(session.currentTime)) / \(SOAPParser.formatUPnPTime(session.duration))",
                image: UIImage(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
            )
            configureVideoPlayback(nowPlayingItem, for: current, isCurrentlyPlaying: isPlaying)
            nowPlayingItem.handler = { _, completion in
                PlayerService.shared.togglePlayPause()
                completion()
            }
            sections.append(CPListSection(items: [nowPlayingItem], header: "正在播放", sectionIndexTitle: nil))
        }

        // MARK: - 2. Continue Watching / Playback History Section
        let historyItems = PlaybackHistory.shared.items
        let currentID = session.currentItem?.id
        let filteredHistory = historyItems.filter { $0.id != currentID }
        if !filteredHistory.isEmpty {
            let recentItems = Array(filteredHistory.prefix(6)).map { historyItem in
                let hasProgress = (historyItem.resumePosition ?? 0) > 0 && (historyItem.duration ?? 0) > 0
                let detail: String
                if hasProgress {
                    detail = "上次观看至 \(SOAPParser.formatUPnPTime(historyItem.resumePosition!)) / \(SOAPParser.formatUPnPTime(historyItem.duration!))"
                } else if historyItem.sourceType == .personalMedia {
                    detail = "个人媒体库"
                } else if historyItem.sourceType == .dlna {
                    detail = "投屏历史"
                } else {
                    detail = "历史播放"
                }

                let item = CPListItem(
                    text: historyItem.title,
                    detailText: detail,
                    image: UIImage(systemName: "clock.arrow.circlepath")
                )
                item.handler = { _, completion in
                    Task {
                        var playItem = historyItem
                        if historyItem.sourceType == .personalMedia,
                           let serverID = historyItem.serverID,
                           let client = MediaServerManager.shared.getClient(for: serverID) {
                            playItem = (try? await client.resolvePlaybackItem(historyItem)) ?? historyItem
                        }
                        await MainActor.run {
                            PlayerService.shared.loadAndPlay(item: playItem, requiresNativePlayback: true)
                        }
                    }
                    completion()
                }
                return item
            }
            sections.append(CPListSection(items: recentItems, header: "继续观看与最近播放", sectionIndexTitle: nil))
        }

        // MARK: - 3. Personal Media Servers Section (Emby / Jellyfin / WebDAV / SMB / fnOS)
        let savedServers = MediaServerManager.shared.savedServers
        if !savedServers.isEmpty {
            let serverItems = savedServers.map { server in
                let item = CPListItem(
                    text: server.name,
                    detailText: serverTypeText(for: server.serverType) + " 媒体库",
                    image: UIImage(systemName: icon(for: server.serverType))
                )
                item.handler = { _, completion in
                    pushServerLibraries(server: server, interfaceController: interfaceController)
                    completion()
                }
                return item
            }
            sections.append(CPListSection(items: serverItems, header: "个人媒体库", sectionIndexTitle: nil))
        }

        // MARK: - 4. Test Streams Section
        let sampleItems = MediaItem.sampleStreams.map { sample in
            let item = CPListItem(
                text: sample.title,
                detailText: sample.mimeType?.contains("mpegURL") == true ? "HLS 视频流" : "MP4 视频",
                image: UIImage(systemName: "film.fill")
            )
            item.handler = { _, completion in
                PlayerService.shared.loadAndPlay(item: sample, requiresNativePlayback: true)
                completion()
            }
            return item
        }
        sections.append(CPListSection(items: sampleItems, header: "内置测试源 (实车验证)", sectionIndexTitle: nil))

        // MARK: - 5. Receiver Status Section
        let statusItem = CPListItem(
            text: UPnPDevice.shared.friendlyName,
            detailText: "DLNA 接收端已就绪 (端口 :\(HTTPServer.shared.port))",
            image: UIImage(systemName: "antenna.radiowaves.left.and.right")
        )
        statusItem.handler = { _, completion in
            completion()
        }
        sections.append(CPListSection(items: [statusItem], header: "车载投送状态", sectionIndexTitle: nil))

        return sections
    }

    public static func buildRootTemplate(interfaceController: CPInterfaceController) -> CPListTemplate {
        let sections = buildRootSections(interfaceController: interfaceController)
        return CPListTemplate(title: "Mivu", sections: sections)
    }

    private static func serverTypeText(for type: MediaServerType) -> String {
        switch type {
        case .emby: return "Emby"
        case .jellyfin: return "Jellyfin"
        case .webDAV: return "WebDAV"
        case .smb: return "SMB 共享"
        case .fnos: return "飞牛私有云"
        }
    }

    private static func icon(for type: MediaServerType) -> String {
        switch type {
        case .emby: return "tv.fill"
        case .jellyfin, .fnos: return "play.square.stack.fill"
        case .webDAV: return "externaldrive.connected.to.line.below"
        case .smb: return "folder.badge.gearshape"
        }
    }

    private static func iconForCollection(_ type: String?) -> String {
        switch type?.lowercased() {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "music": return "music.note"
        case "photos": return "photo"
        case "homevideos": return "video"
        default: return "folder.fill"
        }
    }

    private static func pushServerLibraries(server: SavedServerInfo, interfaceController: CPInterfaceController) {
        guard let client = MediaServerManager.shared.getClient(for: server.id) else { return }

        Task {
            do {
                let libs = try await client.fetchLibraries()
                let items = libs.map { lib in
                    let item = CPListItem(
                        text: lib.name,
                        detailText: lib.collectionType?.capitalized ?? "媒体库",
                        image: UIImage(systemName: iconForCollection(lib.collectionType))
                    )
                    item.handler = { _, completion in
                        pushLibraryVideos(client: client, library: lib, interfaceController: interfaceController)
                        completion()
                    }
                    return item
                }

                await MainActor.run {
                    let template = CPListTemplate(title: server.name, sections: [CPListSection(items: items)])
                    interfaceController.pushTemplate(template, animated: true, completion: nil)
                }
            } catch {
                logger.error("Failed to fetch CarPlay libraries: \(error.localizedDescription)")
            }
        }
    }

    private static func configureVideoPlayback(_ item: CPListItem, for media: MediaItem, isCurrentlyPlaying: Bool = false) {
        guard #available(iOS 26.4, *), CarPlaySceneDelegate.shared?.isVideoPlaybackAvailable == true else { return }
        if media.sourceType == .dlna {
            SSDPService.shared.recordCastDebug("CARPLAY configure elapsed=\(media.resumePosition ?? 0) duration=\(media.duration ?? 0) isPlaying=\(isCurrentlyPlaying)")
        }
        let durationTime: CMTime
        if let d = media.duration, d > 0, !d.isNaN, !d.isInfinite {
            durationTime = CMTime(seconds: d, preferredTimescale: 600)
        } else {
            durationTime = .zero
        }
        let elapsedTime: CMTime
        if let e = media.resumePosition, e > 0, !e.isNaN, !e.isInfinite {
            elapsedTime = CMTime(seconds: e, preferredTimescale: 600)
        } else {
            elapsedTime = .zero
        }
        item.playbackConfiguration = CPPlaybackConfiguration(
            preferredPresentation: .video,
            playbackAction: isCurrentlyPlaying ? .pause : .play,
            elapsedTime: elapsedTime,
            duration: durationTime
        )
    }

    private static func pushLibraryVideos(client: MediaServerProtocol, library: MediaLibrary, interfaceController: CPInterfaceController) {
        Task {
            do {
                let videos = try await client.fetchItems(libraryId: library.id, startIndex: 0, limit: 50)
                let items = videos.map { video in
                    let item = CPListItem(
                        text: video.title,
                        detailText: video.duration != nil && video.duration! > 0 ? SOAPParser.formatUPnPTime(video.duration!) : "视频",
                        image: UIImage(systemName: "play.circle.fill")
                    )
                    item.handler = { _, completion in
                        Task {
                            let resolved = (try? await client.resolvePlaybackItem(video)) ?? video
                            await MainActor.run { PlayerService.shared.loadAndPlay(item: resolved, requiresNativePlayback: true) }
                        }
                        completion()
                    }
                    return item
                }

                await MainActor.run {
                    let template = CPListTemplate(title: library.name, sections: [CPListSection(items: items)])
                    interfaceController.pushTemplate(template, animated: true, completion: nil)
                }
            } catch {
                logger.error("Failed to fetch CarPlay videos: \(error.localizedDescription)")
            }
        }
    }
}
