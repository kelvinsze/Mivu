import XCTest
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
}
