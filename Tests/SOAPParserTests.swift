import XCTest
@testable import Mivu

final class SOAPParserTests: XCTestCase {

    func testFormatAndParseUPnPTime() {
        XCTAssertEqual(SOAPParser.formatUPnPTime(0), "00:00:00")
        XCTAssertEqual(SOAPParser.formatUPnPTime(65), "00:01:05")
        XCTAssertEqual(SOAPParser.formatUPnPTime(3665), "01:01:05")

        XCTAssertEqual(SOAPParser.parseUPnPTime("00:00:00"), 0)
        XCTAssertEqual(SOAPParser.parseUPnPTime("00:01:05"), 65)
        XCTAssertEqual(SOAPParser.parseUPnPTime("01:01:05"), 3665)
    }

    func testExtractTitleFromDIDLLite() {
        let didl = """
        &lt;DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/"&gt;
          &lt;item id="1" parentID="0" restricted="1"&gt;
            &lt;dc:title&gt;Sample Video Title&lt;/dc:title&gt;
            &lt;res protocolInfo="http-get:*:video/mp4:*"&gt;http://192.168.1.100:8000/video.mp4&lt;/res&gt;
          &lt;/item&gt;
        &lt;/DIDL-Lite&gt;
        """
        let title = SOAPParser.extractTitleFromDIDLLite(didl)
        XCTAssertEqual(title, "Sample Video Title")
    }

    func testExtractTitleWithNumericEntities() {
        let didl = """
        &lt;DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/"&gt;
          &lt;item id="1"&gt;
            &lt;dc:title&gt;&#20013;&#25991; &amp;#x6d4b;&amp;#x8bd5;&lt;/dc:title&gt;
          &lt;/item&gt;
        &lt;/DIDL-Lite&gt;
        """
        let title = SOAPParser.extractTitleFromDIDLLite(didl)
        XCTAssertEqual(title, "中文 测试")
    }

    func testParseSOAPActionWithHeaderAndCDATA() {
        let soapXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Header>
            <custom:Auth xmlns:custom="urn:schemas-custom">SecretToken</custom:Auth>
          </s:Header>
          <s:Body>
            <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
              <CurrentURI><![CDATA[http://192.168.1.50:8080/cdata-movie.mp4?token=1&auth=2]]></CurrentURI>
              <CurrentURIMetaData><![CDATA[<DIDL-Lite><dc:title>CDATA Title</dc:title></DIDL-Lite>]]></CurrentURIMetaData>
            </u:SetAVTransportURI>
          </s:Body>
        </s:Envelope>
        """
        guard let data = soapXML.data(using: .utf8) else {
            XCTFail("Failed to convert string to data")
            return
        }

        // Test without SOAPACTION header so actionName is extracted from XML
        let action = SOAPParser.parseAction(bodyData: data, soapActionHeader: nil)
        XCTAssertNotNil(action)
        XCTAssertEqual(action?.actionName, "SetAVTransportURI")
        XCTAssertEqual(action?.parameters["CurrentURI"], "http://192.168.1.50:8080/cdata-movie.mp4?token=1&auth=2")
        XCTAssertEqual(action?.parameters["CurrentURIMetaData"], "<DIDL-Lite><dc:title>CDATA Title</dc:title></DIDL-Lite>")
    }

    func testParseSOAPAction() {
        let soapXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body>
            <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
              <InstanceID>0</InstanceID>
              <CurrentURI>http://192.168.1.50:8080/movie.mp4</CurrentURI>
            </u:SetAVTransportURI>
          </s:Body>
        </s:Envelope>
        """
        guard let data = soapXML.data(using: .utf8) else {
            XCTFail("Failed to convert string to data")
            return
        }

        let action = SOAPParser.parseAction(bodyData: data, soapActionHeader: "\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"")
        XCTAssertNotNil(action)
        XCTAssertEqual(action?.actionName, "SetAVTransportURI")
        XCTAssertEqual(action?.parameters["CurrentURI"], "http://192.168.1.50:8080/movie.mp4")
    }

    func testParseRenderingControlAction() {
        let soapXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body>
            <u:SetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
              <InstanceID>0</InstanceID>
              <Channel>Master</Channel>
              <DesiredVolume>75</DesiredVolume>
            </u:SetVolume>
          </s:Body>
        </s:Envelope>
        """
        guard let data = soapXML.data(using: .utf8) else {
            XCTFail("Failed to convert string to data")
            return
        }

        let action = SOAPParser.parseAction(bodyData: data, soapActionHeader: "\"urn:schemas-upnp-org:service:RenderingControl:1#SetVolume\"")
        XCTAssertNotNil(action)
        XCTAssertEqual(action?.actionName, "SetVolume")
        XCTAssertEqual(action?.parameters["DesiredVolume"], "75")
    }

    func testDeepLinkParsing() {
        #if MIVU_PRO
        let scheme = "mivupro"
        let unsupportedScheme = "mivu"
        #else
        let scheme = "mivu"
        let unsupportedScheme = "mivupro"
        #endif
        let url = URL(string: "\(scheme)://play?url=https%3A%2F%2Fexample.com%2Fstream.m3u8&title=TestStream")!
        let item = URLSource.parseDeepLink(url: url)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.title, "TestStream")
        XCTAssertEqual(item?.url.absoluteString, "https://example.com/stream.m3u8")

        let unsupportedURL = URL(string: "\(unsupportedScheme)://play?url=https%3A%2F%2Fexample.com%2Fstream.m3u8")!
        XCTAssertNil(URLSource.parseDeepLink(url: unsupportedURL))
    }

    func testWebRemoteTemplateRender() {
        let html = WebRemoteTemplate.render(ip: "192.168.1.88", port: 7890, friendlyName: "Mivu Car")
        XCTAssertTrue(html.contains("Mivu 遥控与投送"))
        XCTAssertTrue(html.contains("Mivu Car"))
        XCTAssertTrue(html.contains("/api/play"))
        XCTAssertTrue(html.contains("X-Mivu-Access-Code"))
        XCTAssertTrue(html.contains("access-code"))
    }

    func testWebRemoteRequiresAccessCode() async throws {
        HTTPServer.shared.start()
        for _ in 0..<20 where !HTTPServer.shared.isRunning {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(HTTPServer.shared.isRunning)

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(HTTPServer.shared.port)/api/status"))
        let (_, unauthenticatedResponse) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((unauthenticatedResponse as? HTTPURLResponse)?.statusCode, 401)

        var authenticatedRequest = URLRequest(url: url)
        authenticatedRequest.setValue(HTTPServer.shared.webAccessCode, forHTTPHeaderField: "X-Mivu-Access-Code")
        let (_, authenticatedResponse) = try await URLSession.shared.data(for: authenticatedRequest)
        XCTAssertEqual((authenticatedResponse as? HTTPURLResponse)?.statusCode, 200)
    }

    func testEscapeXML() {
        XCTAssertEqual(SOAPParser.escapeXML("https://example.test/a?x=1&y=<2"), "https://example.test/a?x=1&amp;y=&lt;2")
    }

    // MARK: - Media Server Tests (Pro Only)

    #if MIVU_PRO
    func testSavedServerInfoDoesNotEncodeToken() throws {
        let info = SavedServerInfo(
            name: "Test",
            url: URL(string: "https://example.test")!,
            serverType: .jellyfin,
            username: "user",
            token: "secret-token"
        )
        let data = try JSONEncoder().encode(info)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("secret-token"))
        XCTAssertFalse(json.contains("\"token\""))
        XCTAssertFalse(json.contains("\"username\""))
        XCTAssertFalse(json.contains("\"userId\""))
        KeychainTokenStore.delete(for: info.id)
    }

    func testPlaybackInfoSelectionPrefersDirectPlay() {
        let payload: [String: Any] = [
            "PlaySessionId": "session-1",
            "MediaSources": [[
                "Id": "source-1",
                "SupportsDirectPlay": true,
                "SupportsDirectStream": true,
                "SupportsTranscoding": true,
                "DirectStreamUrl": "Videos/abc/master.m3u8",
                "TranscodingUrl": "Videos/abc/transcode.m3u8"
            ]],
            "UserData": ["PlaybackPositionTicks": 20_000_000.0]
        ]
        let info = MediaPlaybackInfoSelector.select(itemId: "abc", baseURL: URL(string: "https://media.test/")!, payload: payload)
        XCTAssertEqual(info?.method, .directPlay)
        XCTAssertEqual(info?.url.absoluteString, "https://media.test/Videos/abc/stream?Static=true&MediaSourceId=source-1")
        XCTAssertEqual(info?.resumePosition, 2.0)
        XCTAssertEqual(info?.mediaSourceId, "source-1")
    }

    func testPlaybackInfoSelectionUsesHLSTranscodeWhenDirectPlayIsUnavailable() {
        let payload: [String: Any] = [
            "MediaSources": [[
                "Id": "source-1",
                "SupportsDirectPlay": false,
                "SupportsTranscoding": true,
                "TranscodingUrl": "Videos/abc/transcode.m3u8"
            ]]
        ]

        let info = MediaPlaybackInfoSelector.select(itemId: "abc", baseURL: URL(string: "https://media.test/")!, payload: payload)
        XCTAssertEqual(info?.method, .transcode)
        XCTAssertEqual(info?.url.absoluteString, "https://media.test/Videos/abc/transcode.m3u8")
    }

    func testCredentialMigrationOnlyRunsForLegacyFields() {
        XCTAssertFalse(MediaServerCredentialMigration.shouldMigrate(hasUsername: false, hasUserId: false, hasToken: false))
        XCTAssertTrue(MediaServerCredentialMigration.shouldMigrate(hasUsername: true, hasUserId: false, hasToken: false))
    }

    func testUnknownMediaServerTypeFailsDecoding() {
        let data = Data("{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"x\",\"url\":\"https://example.test\",\"serverType\":\"plex\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SavedServerInfo.self, from: data))
    }

    func testMediaServerTypeCodable() throws {
        let data = try JSONEncoder().encode(MediaServerType.emby)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"emby\"")
        XCTAssertEqual(try JSONDecoder().decode(MediaServerType.self, from: data), .emby)
        XCTAssertEqual(try JSONDecoder().decode(MediaServerType.self, from: Data("\"webdav\"".utf8)), .webDAV)
        XCTAssertEqual(try JSONDecoder().decode(MediaServerType.self, from: Data("\"smb\"".utf8)), .smb)
        XCTAssertEqual(try JSONDecoder().decode(MediaServerType.self, from: Data("\"fnos\"".utf8)), .fnos)
    }
    #endif

    func testSSDPMSearchParsingAndResponseConstruction() {
        let packet = "M-SEARCH * HTTP/1.1\r\nMAN: \"ssdp:discover\"\r\nST: ssdp:all\r\n\r\n"
        XCTAssertEqual(SSDPService.parseMSearchTarget(packet), "ssdp:all")
        let responses = SSDPService.mSearchResponses(for: "ssdp:all", udn: "uuid:test", location: "http://127.0.0.1:7890/description.xml", date: "now")
        XCTAssertEqual(responses.count, 6)
        XCTAssertTrue(String(decoding: responses[0], as: UTF8.self).contains("HTTP/1.1 200 OK"))
    }

    func testSSDPDiscoveryPathClassification() {
        XCTAssertEqual(SSDPService.discoveryPath(forRemoteHost: "127.0.0.1"), .loopbackUnicast)
        XCTAssertEqual(
            SSDPService.discoveryPath(forRemoteHost: "192.168.1.10", knownPath: .bsdMulticast),
            .bsdMulticast
        )
        XCTAssertEqual(SSDPService.discoveryPath(forRemoteHost: "203.0.113.1"), .unknown)
        XCTAssertEqual(SSDPService.discoveryPath(forHint: "bsd-msearch"), .bsdMulticast)
        XCTAssertEqual(SSDPService.discoveryPath(forHint: "nw-notify"), .networkFramework)
        XCTAssertEqual(SSDPService.discoveryPath(forHint: "loopback-multicast"), .loopbackMulticast)
        XCTAssertEqual(SSDPService.discoveryPath(forHint: "loopback-unicast"), .loopbackUnicast)
        XCTAssertNil(SSDPService.discoveryPath(forHint: "vpn-boost"))
    }

    func testHistoryItemStripsHeaders() {
        let item = MediaItem(title: "Video", url: URL(string: "https://media.test/video.mp4")!, headers: ["Authorization": "Bearer secret", "Cookie": "session=secret"])
        XCTAssertNil(item.withoutSensitiveHeaders().headers)
    }

    func testReceiverServiceDescriptionsHaveResolvableArguments() {
        let device = UPnPDevice.shared
        let description = device.deviceDescriptionXML(hostIP: "192.168.1.2")
        XCTAssertEqual(description.components(separatedBy: "<eventSubURL></eventSubURL>").count - 1, 3)
        for xml in [device.avTransportSCPD(), device.renderingControlSCPD(), device.connectionManagerSCPD()] {
            let inspector = SCPDContractInspector()
            let parser = XMLParser(data: Data(xml.utf8))
            parser.delegate = inspector
            XCTAssertTrue(parser.parse())
            XCTAssertFalse(inspector.variables.isEmpty)
            XCTAssertFalse(inspector.actionArgumentCounts.isEmpty)
            XCTAssertTrue(inspector.actionArgumentCounts.allSatisfy { $0 > 0 })
            XCTAssertTrue(inspector.references.allSatisfy { inspector.variables.contains($0) })
            XCTAssertFalse(xml.contains("sendEvents=\"yes\""), "No event subscription endpoint is implemented")
        }
    }

    func testDiscoveryLocationMatchesControllerRoute() {
        XCTAssertEqual(SSDPService.responseHost(remoteHost: "127.0.0.1", localAddresses: [], routeAddress: "10.0.0.2", fallbackAddress: "10.0.0.2"), "127.0.0.1")
        XCTAssertEqual(SSDPService.responseHost(remoteHost: "192.168.9.151", localAddresses: ["192.168.9.151"], routeAddress: "127.0.0.1", fallbackAddress: "10.0.0.2"), "192.168.9.151")
        XCTAssertEqual(SSDPService.responseHost(remoteHost: "192.168.2.5", localAddresses: ["192.168.1.2", "192.168.2.2"], routeAddress: "192.168.2.2", fallbackAddress: "192.168.1.2"), "192.168.2.2")
        XCTAssertEqual(SSDPService.descriptionLocation(host: "192.168.2.2", port: 7890), "http://192.168.2.2:7890/description.xml")
    }
}

private final class SCPDContractInspector: NSObject, XMLParserDelegate {
    var variables = Set<String>()
    var references: [String] = []
    var actionArgumentCounts: [Int] = []
    private var elements: [String] = []
    private var value = ""
    private var argumentCount = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        elements.append(elementName)
        value = ""
        if elementName == "action" { argumentCount = 0 }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { value += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName == "name", elements.dropLast().last == "stateVariable" { variables.insert(text) }
        if elementName == "relatedStateVariable" { references.append(text) }
        if elementName == "argument" { argumentCount += 1 }
        if elementName == "action" { actionArgumentCounts.append(argumentCount) }
        elements.removeLast()
    }
}
