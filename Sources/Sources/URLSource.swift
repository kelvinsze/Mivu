import Foundation
import UIKit

/// Manages direct URL inputs and clipboard stream auto-detection.
public final class URLSource {

    /// Checks system pasteboard for playable video or HLS streams.
    @MainActor
    public static func detectPlayableURLInClipboard() -> URL? {
        guard let string = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        let ext = url.pathExtension.lowercased()
        let playableExtensions = ["m3u8", "mp4", "mov", "m4v", "ts", "webm", "mkv", "mpd"]
        if playableExtensions.contains(ext) || string.contains(".m3u8") || string.contains(".mp4") {
            return url
        }

        return nil
    }

    /// Parses the app-specific URL Scheme deep link (e.g. `mivu://play?url=http://...&title=Sample`).
    public static func parseDeepLink(url: URL) -> MediaItem? {
        guard url.scheme?.lowercased() == deepLinkScheme else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        var targetUrlString: String?
        var title: String?

        if let queryItems = components.queryItems {
            for item in queryItems {
                if item.name.lowercased() == "url" {
                    targetUrlString = item.value
                } else if item.name.lowercased() == "title" {
                    title = item.value
                }
            }
        }

        guard let urlStr = targetUrlString, let targetUrl = URL(string: urlStr) else {
            return nil
        }

        return MediaItem(
            title: title ?? targetUrl.lastPathComponent,
            url: targetUrl,
            sourceType: .directUrl,
            originator: "Deep Link"
        )
    }

    private static let deepLinkScheme: String = {
        #if MIVU_PRO
        "mivupro"
        #else
        "mivu"
        #endif
    }()
}
