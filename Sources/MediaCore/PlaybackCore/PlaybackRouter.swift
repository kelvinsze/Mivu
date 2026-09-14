import Foundation

public enum PlaybackRoute: String, Equatable, Sendable {
    case native
    case mpv
}

/// Conservative policy boundary for selecting a non-Native decoder.
///
/// A generic Emby/Jellyfin `/stream` URL has no extension and therefore stays
/// Native. MPV is selected only when the caller supplies an explicit container
/// hint and the framework is operational.
public enum PlaybackRouter {
    private static let mpvContainers: Set<String> = ["mkv", "webm", "avi", "flv", "ts", "m2ts", "ogv"]

    public static func route(for request: PlaybackRequest, mpvAvailable: Bool) -> PlaybackRoute {
        if request.url.scheme?.lowercased() == "mivu-smb" {
            guard mpvAvailable, SMBLocalHTTPProxy.shared.url(for: request.url) != nil else {
                return .native
            }
        }
        guard mpvAvailable else {
            return .native
        }
        let container = request.containerHint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return mpvContainers.contains(container ?? "") ? .mpv : .native
    }
}
