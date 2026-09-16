import XCTest
import AVFoundation
@testable import Mivu

final class PlaybackCoreTests: XCTestCase {
    func testMediaItemCreatesNarrowPlaybackRequest() {
        let item = MediaItem(
            title: "Test",
            url: URL(string: "https://example.com/video.mp4")!,
            headers: ["Authorization": "Bearer test"],
            resumePosition: 42
        )

        let request = item.playbackRequest

        XCTAssertEqual(request.url, item.url)
        XCTAssertEqual(request.headers["Authorization"], "Bearer test")
        XCTAssertEqual(request.startPosition, 42)
    }

    func testPlaybackRequestClampsNegativeStartPosition() {
        let request = PlaybackRequest(
            url: URL(string: "https://example.com/video.mp4")!,
            startPosition: -10
        )

        XCTAssertEqual(request.startPosition, 0)
    }

    func testPlaybackRouterKeepsGenericServerStreamNative() {
        let request = PlaybackRequest(url: URL(string: "https://media.test/Items/1/stream")!)

        XCTAssertEqual(PlaybackRouter.route(for: request, mpvAvailable: true), .native)
    }

    func testPlaybackRouterUsesMPVOnlyForExplicitContainerHint() {
        let request = PlaybackRequest(
            url: URL(string: "https://media.test/video")!,
            containerHint: "mkv"
        )

        XCTAssertEqual(PlaybackRouter.route(for: request, mpvAvailable: true), .mpv)
        XCTAssertEqual(PlaybackRouter.route(for: request, mpvAvailable: false), .native)
    }

    func testPlaybackRouterKeepsNativeContainerOnAVPlayerEvenWithNonNativeCodec() {
        let request = PlaybackRequest(
            url: URL(string: "https://media.test/video.mp4")!,
            containerHint: "mp4",
            videoCodecHint: "hevc"
        )

        XCTAssertEqual(PlaybackRouter.route(for: request, mpvAvailable: true), .native)
        XCTAssertEqual(PlaybackRouter.route(for: request, mpvAvailable: false), .native)
    }

    func testMediaItemDerivesKnownContainerHintWithoutChangingGenericURLs() {
        let matroska = MediaItem(
            title: "Matroska",
            url: URL(string: "https://media.test/video.mkv")!
        )
        let generic = MediaItem(
            title: "Server stream",
            url: URL(string: "https://media.test/Items/1/stream")!
        )

        XCTAssertEqual(matroska.playbackRequest.containerHint, "mkv")
        XCTAssertNil(generic.playbackRequest.containerHint)
    }

    func testMediaItemUsesServerContainerHintForGenericStreamURL() {
        let item = MediaItem(
            title: "Matroska server stream",
            url: URL(string: "https://media.test/Items/1/stream")!,
            containerHint: "mkv"
        )

        XCTAssertEqual(item.playbackRequest.containerHint, "mkv")
        XCTAssertEqual(PlaybackRouter.route(for: item.playbackRequest, mpvAvailable: true), .mpv)
    }

    func testMediaItemAdvancesToNextPlaybackAlternative() {
        var item = MediaItem(
            title: "Server stream",
            url: URL(string: "https://media.test/direct")!,
            playSessionID: "session-direct",
            playbackAlternatives: [
                PlaybackAlternative(
                    url: URL(string: "https://media.test/transcode.m3u8")!,
                    playSessionID: "session-transcode",
                    mediaSourceID: "source-1"
                )
            ]
        )

        XCTAssertTrue(item.advanceToNextPlaybackAlternative())
        XCTAssertEqual(item.url.absoluteString, "https://media.test/transcode.m3u8")
        XCTAssertEqual(item.playSessionID, "session-transcode")
        XCTAssertEqual(item.mediaSourceID, "source-1")
        XCTAssertFalse(item.advanceToNextPlaybackAlternative())
    }

    func testEngineSnapshotRetainsPlaybackState() {
        let snapshot = PlaybackEngineSnapshot(
            status: .loading,
            currentTime: 12,
            duration: 120,
            bufferedTime: 30,
            playbackRate: 1.25,
            isMuted: true,
            volume: 0.5,
            errorMessage: nil
        )

        XCTAssertEqual(snapshot.status, .loading)
        XCTAssertEqual(snapshot.currentTime, 12)
        XCTAssertEqual(snapshot.duration, 120)
        XCTAssertEqual(snapshot.bufferedTime, 30)
        XCTAssertEqual(snapshot.playbackRate, 1.25)
        XCTAssertTrue(snapshot.isMuted)
        XCTAssertEqual(snapshot.volume, 0.5)
    }

    func testPlaybackInfoPreservesCandidatesInPreferenceOrder() {
        let payload: [String: Any] = [
            "PlaySessionId": "session-1",
            "MediaSources": [[
                "Id": "source-1",
                "Container": "matroska",
                "MediaStreams": [["Type": "Video", "Codec": "h264"]],
                "SupportsDirectPlay": true,
                "SupportsDirectStream": true,
                "SupportsTranscoding": true,
                "DirectStreamUrl": "Videos/item/remux.m3u8",
                "TranscodingUrl": "Videos/item/transcode.m3u8"
            ]]
        ]

        let info = MediaPlaybackInfoSelector.select(
            itemId: "item",
            baseURL: URL(string: "https://media.test/")!,
            payload: payload
        )

        XCTAssertEqual(info?.candidates.map(\.method), [.directPlay, .directStream, .transcode])
        XCTAssertEqual(info?.method, .directPlay)
        XCTAssertEqual(info?.playSessionId, "session-1")
        XCTAssertEqual(info?.candidates.first?.containerHint, "mkv")
        XCTAssertEqual(info?.candidates.first?.videoCodecHint, "h264")
        XCTAssertEqual(info?.candidates[1].url.absoluteString, "https://media.test/Videos/item/remux.m3u8")
    }

    func testPlaybackInfoSelectorReturnsNilWithoutCandidates() {
        let payload: [String: Any] = [
            "MediaSources": [[
                "Id": "source-1",
                "SupportsDirectPlay": false,
                "SupportsDirectStream": false,
                "SupportsTranscoding": false
            ]]
        ]

        XCTAssertNil(MediaPlaybackInfoSelector.select(
            itemId: "item",
            baseURL: URL(string: "https://media.test/")!,
            payload: payload
        ))
    }

    func testPlaybackInfoExtractsEmbeddedAndExternalSubtitleTracks() {
        let payload: [String: Any] = [
            "MediaSources": [[
                "Id": "source-1",
                "SupportsDirectPlay": true,
                "MediaStreams": [
                    ["Type": "Subtitle", "Index": 2, "Language": "zh-CN", "Codec": "ass", "IsDefault": true],
                    ["Type": "Subtitle", "Index": 3, "Language": "en", "Codec": "srt", "IsExternal": true]
                ]
            ]]
        ]

        let info = MediaPlaybackInfoSelector.select(
            itemId: "item",
            baseURL: URL(string: "https://media.test/")!,
            payload: payload
        )

        XCTAssertEqual(info?.subtitleTracks.count, 2)
        XCTAssertEqual(info?.subtitleTracks[0].format, .ass)
        XCTAssertTrue(info?.subtitleTracks[0].isEmbedded ?? false)
        XCTAssertNil(info?.subtitleTracks[0].url)
        XCTAssertEqual(info?.subtitleTracks[1].format, .srt)
        XCTAssertFalse(info?.subtitleTracks[1].isEmbedded ?? true)
        XCTAssertEqual(info?.subtitleTracks[1].url?.path, "/Videos/item/source-1/Subtitles/3/Stream.srt")
    }

    func testPlaybackErrorClassifierIdentifiesFormatAndDecodeErrors() {
        let formatError = NSError(domain: AVFoundationErrorDomain, code: -11828, userInfo: [NSLocalizedDescriptionKey: "File format not supported"])
        let reason1 = PlaybackErrorClassifier.classifyNSError(formatError)
        XCTAssertTrue(reason1.isEligibleForTranscodeFallback)
        XCTAssertEqual(reason1.categoryName, "mediaFormatOrDecode")

        let decoderError = NSError(domain: AVFoundationErrorDomain, code: -11833, userInfo: [NSLocalizedDescriptionKey: "Decoder not found"])
        let reason2 = PlaybackErrorClassifier.classifyNSError(decoderError)
        XCTAssertTrue(reason2.isEligibleForTranscodeFallback)

        let coreMediaError = NSError(domain: "CoreMediaErrorDomain", code: -12842, userInfo: [NSLocalizedDescriptionKey: "Unsupported format reader"])
        let reason3 = PlaybackErrorClassifier.classifyNSError(coreMediaError)
        XCTAssertTrue(reason3.isEligibleForTranscodeFallback)

        // Underlying error wrapped inside generic AVErrorUnknown (-11800)
        let wrapped = NSError(domain: AVFoundationErrorDomain, code: -11800, userInfo: [
            NSLocalizedDescriptionKey: "The operation could not be completed",
            NSUnderlyingErrorKey: coreMediaError
        ])
        let reason4 = PlaybackErrorClassifier.classifyNSError(wrapped)
        XCTAssertTrue(reason4.isEligibleForTranscodeFallback)

        let decodeFailed = NSError(domain: AVFoundationErrorDomain, code: -11848, userInfo: [NSLocalizedDescriptionKey: "Cannot decode video"])
        XCTAssertTrue(PlaybackErrorClassifier.classifyNSError(decodeFailed).isEligibleForTranscodeFallback)

        let audioFormatError = NSError(domain: NSOSStatusErrorDomain, code: 1718449257, userInfo: [NSLocalizedDescriptionKey: "Unsupported audio format"])
        XCTAssertTrue(PlaybackErrorClassifier.classifyNSError(audioFormatError).isEligibleForTranscodeFallback)
    }

    func testPlaybackErrorClassifierBlocksNetworkErrors() {
        let offlineError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
        let reason1 = PlaybackErrorClassifier.classifyNSError(offlineError)
        XCTAssertFalse(reason1.isEligibleForTranscodeFallback)
        XCTAssertEqual(reason1.categoryName, "network")

        let timeoutError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: "The request timed out."])
        let reason2 = PlaybackErrorClassifier.classifyNSError(timeoutError)
        XCTAssertFalse(reason2.isEligibleForTranscodeFallback)
        XCTAssertEqual(reason2.categoryName, "network")

        // Network error wrapped inside AVErrorUnknown
        let wrapped = NSError(domain: AVFoundationErrorDomain, code: -11800, userInfo: [
            NSLocalizedDescriptionKey: "The operation could not be completed",
            NSUnderlyingErrorKey: timeoutError
        ])
        let reason3 = PlaybackErrorClassifier.classifyNSError(wrapped)
        XCTAssertFalse(reason3.isEligibleForTranscodeFallback)
        XCTAssertEqual(reason3.categoryName, "network")

        let badResponse = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse, userInfo: [NSLocalizedDescriptionKey: "Bad response"])
        let reason4 = PlaybackErrorClassifier.classifyNSError(badResponse)
        XCTAssertFalse(reason4.isEligibleForTranscodeFallback)
        XCTAssertEqual(reason4.categoryName, "server")
    }

    func testPlaybackErrorClassifierBlocksAuthenticationAndServerErrors() {
        let authError = NSError(domain: NSURLErrorDomain, code: NSURLErrorUserCancelledAuthentication, userInfo: [NSLocalizedDescriptionKey: "Authentication cancelled"])
        let reason1 = PlaybackErrorClassifier.classifyNSError(authError)
        XCTAssertFalse(reason1.isEligibleForTranscodeFallback)
        XCTAssertEqual(reason1.categoryName, "authentication")

        // MPV errors
        let mpvAuth = PlaybackErrorClassifier.classifyMPV(error: 0, message: "Server returned 401 Unauthorized")
        XCTAssertFalse(mpvAuth.isEligibleForTranscodeFallback)
        XCTAssertEqual(mpvAuth.categoryName, "authentication")

        let mpvServer = PlaybackErrorClassifier.classifyMPV(error: 0, message: "HTTP 500 Internal Server Error")
        XCTAssertFalse(mpvServer.isEligibleForTranscodeFallback)
        XCTAssertEqual(mpvServer.categoryName, "server")

        let mpvFormat = PlaybackErrorClassifier.classifyMPV(error: -14, message: "unsupported format or demuxer failed")
        XCTAssertTrue(mpvFormat.isEligibleForTranscodeFallback)
        XCTAssertEqual(mpvFormat.categoryName, "mediaFormatOrDecode")
    }

    func testPlaybackAlternativePreservesMethodAndAdvances() {
        var item = MediaItem(
            title: "Server stream",
            url: URL(string: "https://media.test/direct")!,
            playSessionID: "session-direct",
            playbackAlternatives: [
                PlaybackAlternative(
                    url: URL(string: "https://media.test/transcode.m3u8")!,
                    method: .transcode,
                    playSessionID: "session-transcode",
                    mediaSourceID: "source-1"
                )
            ]
        )

        XCTAssertEqual(item.playbackAlternatives?.first?.method, .transcode)
        XCTAssertTrue(item.advanceToNextPlaybackAlternative())
        XCTAssertEqual(item.url.absoluteString, "https://media.test/transcode.m3u8")
        XCTAssertEqual(item.playSessionID, "session-transcode")
    }

    func testEngineSnapshotRetainsFailureReason() {
        let failure = PlaybackFailureReason.mediaFormatOrDecode(description: "Unsupported codec", code: -11828)
        let snapshot = PlaybackEngineSnapshot(
            status: .failed,
            errorMessage: "Unsupported codec",
            failureReason: failure
        )

        XCTAssertEqual(snapshot.status, .failed)
        XCTAssertEqual(snapshot.failureReason, failure)
        XCTAssertTrue(snapshot.failureReason?.isEligibleForTranscodeFallback ?? false)
    }
}
