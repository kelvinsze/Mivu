import Foundation
import CarPlay
/// Reads the official CarPlay Video in Car session capability.
public enum CarPlayVideoPresentation {
#if DEBUG
    public static let drivingVideoRestrictionDetectionKey = "mivu_debug_carplay_driving_video_restriction_detection_enabled"

    public static var isDrivingVideoRestrictionDetectionEnabled: Bool {
        UserDefaults.standard.object(forKey: drivingVideoRestrictionDetectionKey) as? Bool ?? true
    }
#endif

    /// Returns the vehicle capability reported by the CarPlay system without test overrides.
    public static func isSystemVideoPlaybackSupported(sessionConfiguration: CPSessionConfiguration?) -> Bool {
        guard let sessionConfiguration else { return false }
        if #available(iOS 26.4, *) {
            return sessionConfiguration.supportsVideoPlayback
        }
        return false
    }

    /// Checks if the connected CarPlay session allows video playback in the car.
    public static func isVideoPlaybackSupported(sessionConfiguration: CPSessionConfiguration?) -> Bool {
        if isSystemVideoPlaybackSupported(sessionConfiguration: sessionConfiguration) {
            return true
        }
#if DEBUG
        return !isDrivingVideoRestrictionDetectionEnabled
#else
        return false
#endif
    }

}
