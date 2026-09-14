import Foundation
import OSLog

private let logger = Logger(subsystem: "com.kelvinsze.mivu", category: "AVTransportService")

/// Handles UPnP AVTransport and RenderingControl SOAP actions, bridging them to PlayerService.
public final class AVTransportService: @unchecked Sendable {
    public static let shared = AVTransportService()

    private let avTransportServiceType = "urn:schemas-upnp-org:service:AVTransport:1"
    private let renderingControlServiceType = "urn:schemas-upnp-org:service:RenderingControl:1"
    private let connectionManagerServiceType = "urn:schemas-upnp-org:service:ConnectionManager:1"

    private init() {}

    /// Dispatches an incoming SOAP action request and produces the response XML string.
    public func handleRequest(action: SOAPActionRequest) async -> (statusCode: Int, responseBody: String) {
        logger.info("Handling SOAP action: \(action.actionName) for service: \(action.serviceType)")

        switch action.actionName {
        // MARK: - AVTransport Actions

        case "SetAVTransportURI":
            guard let uriString = action.parameters["CurrentURI"], let url = URL(string: uriString) else {
                return (500, SOAPParser.makeSOAPFault(errorCode: 714, errorDescription: "Illegal MIME-Type or Invalid URI"))
            }

            let metaData = action.parameters["CurrentURIMetaData"] ?? ""
            let title = SOAPParser.extractTitleFromDIDLLite(metaData) ?? url.lastPathComponent

            let item = MediaItem(
                title: title.isEmpty ? "Cast Media" : title,
                url: url,
                sourceType: .dlna,
                originator: "DLNA Cast"
            )

            await MainActor.run {
                PlayerService.shared.loadAndPlay(
                    item: item,
                    origin: "SOAP.SetAVTransportURI",
                    requiresNativePlayback: CarPlaySceneDelegate.shared?.isConnected == true
                )
                CarPlaySceneDelegate.shared?.presentIncomingPlayback()
            }

            let body = SOAPParser.makeSOAPResponse(
                actionName: "SetAVTransportURI",
                serviceType: avTransportServiceType,
                responseContent: ""
            )
            return (200, body)

        case "Play":
            await MainActor.run {
                PlayerService.shared.play()
            }
            let body = SOAPParser.makeSOAPResponse(
                actionName: "Play",
                serviceType: avTransportServiceType,
                responseContent: ""
            )
            return (200, body)

        case "Pause":
            await MainActor.run {
                PlayerService.shared.pause()
            }
            let body = SOAPParser.makeSOAPResponse(
                actionName: "Pause",
                serviceType: avTransportServiceType,
                responseContent: ""
            )
            return (200, body)

        case "Stop":
            await MainActor.run {
                PlayerService.shared.stop()
            }
            let body = SOAPParser.makeSOAPResponse(
                actionName: "Stop",
                serviceType: avTransportServiceType,
                responseContent: ""
            )
            return (200, body)

        case "Seek":
            SSDPService.shared.recordCastDebug("SOAP Seek unit=\(action.parameters["Unit"] ?? "missing") target=\(action.parameters["Target"] ?? "missing")")
            if let target = action.parameters["Target"] {
                let seconds = SOAPParser.parseUPnPTime(target)
                await MainActor.run {
                    PlayerService.shared.seek(to: seconds, origin: "SOAP.Seek")
                }
            }
            let body = SOAPParser.makeSOAPResponse(
                actionName: "Seek",
                serviceType: avTransportServiceType,
                responseContent: ""
            )
            return (200, body)

        case "GetTransportInfo":
            let session = await MainActor.run { PlayerService.shared.session }
            let state: String
            switch session.status {
            case .playing: state = "PLAYING"
            case .paused: state = "PAUSED_PLAYBACK"
            case .loading: state = "TRANSITIONING"
            case .stopped, .idle: state = "STOPPED"
            case .failed: state = "STOPPED"
            }

            let content = """
                  <CurrentTransportState>\(state)</CurrentTransportState>
                  <CurrentTransportStatus>OK</CurrentTransportStatus>
                  <CurrentSpeed>1</CurrentSpeed>
            """
            if session.currentItem?.sourceType == .dlna {
                SSDPService.shared.recordCastDebug("SOAP GetTransportInfo response state=\(state) status=OK")
            }
            let body = SOAPParser.makeSOAPResponse(
                actionName: "GetTransportInfo",
                serviceType: avTransportServiceType,
                responseContent: content
            )
            return (200, body)

        case "GetPositionInfo":
            let session = await MainActor.run { PlayerService.shared.session }
            let durationStr = SOAPParser.formatUPnPTime(session.duration)
            let currentStr = SOAPParser.formatUPnPTime(session.currentTime)
            let uri = SOAPParser.escapeXML(session.currentItem?.url.absoluteString ?? "")

            if session.currentItem?.sourceType == .dlna {
                SSDPService.shared.recordCastDebug("SOAP GetPositionInfo response position=\(currentStr) duration=\(durationStr)")
            }

            let content = """
                  <Track>1</Track>
                  <TrackDuration>\(durationStr)</TrackDuration>
                  <TrackMetaData></TrackMetaData>
                  <TrackURI>\(uri)</TrackURI>
                  <RelTime>\(currentStr)</RelTime>
                  <AbsTime>\(currentStr)</AbsTime>
                  <RelCount>2147483647</RelCount>
                  <AbsCount>2147483647</AbsCount>
            """
            let body = SOAPParser.makeSOAPResponse(
                actionName: "GetPositionInfo",
                serviceType: avTransportServiceType,
                responseContent: content
            )
            return (200, body)

        case "GetMediaInfo":
            let session = await MainActor.run { PlayerService.shared.session }
            let durationStr = SOAPParser.formatUPnPTime(session.duration)
            let uri = SOAPParser.escapeXML(session.currentItem?.url.absoluteString ?? "")

            let content = """
                  <NrTracks>1</NrTracks>
                  <MediaDuration>\(durationStr)</MediaDuration>
                  <CurrentURI>\(uri)</CurrentURI>
                  <CurrentURIMetaData></CurrentURIMetaData>
                  <NextURI></NextURI>
                  <NextURIMetaData></NextURIMetaData>
                  <PlayMedium>NETWORK</PlayMedium>
                  <RecordMedium>NOT_IMPLEMENTED</RecordMedium>
                  <WriteStatus>NOT_IMPLEMENTED</WriteStatus>
            """
            let body = SOAPParser.makeSOAPResponse(
                actionName: "GetMediaInfo",
                serviceType: avTransportServiceType,
                responseContent: content
            )
            return (200, body)

        case "GetTransportSettings":
            let content = """
                  <PlayMode>NORMAL</PlayMode>
                  <RecQualityMode>NOT_IMPLEMENTED</RecQualityMode>
            """
            let body = SOAPParser.makeSOAPResponse(
                actionName: "GetTransportSettings",
                serviceType: avTransportServiceType,
                responseContent: content
            )
            return (200, body)

        // MARK: - RenderingControl Actions

        case "SetVolume":
            if let volStr = action.parameters["DesiredVolume"], let volInt = Float(volStr) {
                let clamped = max(0, min(volInt / 100.0, 1.0))
                await MainActor.run {
                    PlayerService.shared.setVolume(clamped)
                }
            }
            let body = SOAPParser.makeSOAPResponse(
                actionName: "SetVolume",
                serviceType: renderingControlServiceType,
                responseContent: ""
            )
            return (200, body)

        case "GetVolume":
            let session = await MainActor.run { PlayerService.shared.session }
            let volInt = Int(session.volume * 100.0)
            let content = """
                  <CurrentVolume>\(volInt)</CurrentVolume>
            """
            let body = SOAPParser.makeSOAPResponse(
                actionName: "GetVolume",
                serviceType: renderingControlServiceType,
                responseContent: content
            )
            return (200, body)

        case "SetMute":
            let muteDesired = (action.parameters["DesiredMute"] == "1" || action.parameters["DesiredMute"]?.lowercased() == "true")
            await MainActor.run {
                PlayerService.shared.setMuted(muteDesired)
            }
            let body = SOAPParser.makeSOAPResponse(
                actionName: "SetMute",
                serviceType: renderingControlServiceType,
                responseContent: ""
            )
            return (200, body)

        case "GetMute":
            let session = await MainActor.run { PlayerService.shared.session }
            let muteStr = session.isMuted ? "1" : "0"
            let content = """
                  <CurrentMute>\(muteStr)</CurrentMute>
            """
            let body = SOAPParser.makeSOAPResponse(
                actionName: "GetMute",
                serviceType: renderingControlServiceType,
                responseContent: content
            )
            return (200, body)

        // MARK: - ConnectionManager Actions

        case "GetProtocolInfo":
            let content = """
                  <Source></Source>
                  <Sink>http-get:*:video/mp4:*,http-get:*:video/quicktime:*,http-get:*:application/x-mpegURL:*,http-get:*:audio/mpeg:*</Sink>
            """
            let body = SOAPParser.makeSOAPResponse(
                actionName: "GetProtocolInfo",
                serviceType: connectionManagerServiceType,
                responseContent: content
            )
            return (200, body)

        case "GetCurrentConnectionIDs":
            let content = "<ConnectionIDs>0</ConnectionIDs>"
            let body = SOAPParser.makeSOAPResponse(
                actionName: "GetCurrentConnectionIDs",
                serviceType: connectionManagerServiceType,
                responseContent: content
            )
            return (200, body)

        case "GetCurrentConnectionInfo":
            let content = """
                  <RcsID>0</RcsID>
                  <AVTransportID>0</AVTransportID>
                  <ProtocolInfo>http-get:*:*:*</ProtocolInfo>
                  <PeerConnectionManager></PeerConnectionManager>
                  <PeerConnectionID>-1</PeerConnectionID>
                  <Direction>Input</Direction>
                  <Status>OK</Status>
            """
            let body = SOAPParser.makeSOAPResponse(
                actionName: "GetCurrentConnectionInfo",
                serviceType: connectionManagerServiceType,
                responseContent: content
            )
            return (200, body)

        default:
            logger.warning("Unsupported SOAP action: \(action.actionName)")
            return (500, SOAPParser.makeSOAPFault(errorCode: 401, errorDescription: "Invalid Action"))
        }
    }
}
