import Foundation
import OSLog

private let logger = Logger(subsystem: "com.kold.mivu", category: "SOAPParser")

/// Represents a parsed UPnP SOAP action.
public struct SOAPActionRequest {
    public let serviceType: String
    public let actionName: String
    public let parameters: [String: String]
}

/// Helper for parsing UPnP SOAP envelopes and DIDL-Lite metadata, and constructing SOAP XML responses.
public final class SOAPParser {

    /// Parses incoming SOAP action and parameters from HTTP request body and SOAPACTION header.
    public static func parseAction(bodyData: Data, soapActionHeader: String?) -> SOAPActionRequest? {
        // First try to extract action name from SOAPACTION header if present, e.g. "urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI"
        var serviceType = "urn:schemas-upnp-org:service:AVTransport:1"
        var actionName = ""

        if let header = soapActionHeader?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) {
            let components = header.split(separator: "#")
            if components.count == 2 {
                serviceType = String(components[0])
                actionName = String(components[1])
            }
        }

        // XML parser to extract action parameters
        let xmlParser = SOAPXMLHelper(data: bodyData)
        let parsed = xmlParser.parse()

        if actionName.isEmpty {
            actionName = parsed.actionName
        }

        guard !actionName.isEmpty else {
            logger.warning("Failed to identify SOAP action from request.")
            return nil
        }

        return SOAPActionRequest(serviceType: serviceType, actionName: actionName, parameters: parsed.parameters)
    }

    /// Extracts video title from DIDL-Lite XML metadata string if present.
    public static func extractTitleFromDIDLLite(_ didlString: String) -> String? {
        guard !didlString.isEmpty else { return nil }
        let unescaped = unescapeXML(didlString)
        let pattern = "<dc:title[^>]*>(.*?)</dc:title>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: unescaped, options: [], range: NSRange(location: 0, length: unescaped.utf16.count)),
           let titleRange = Range(match.range(at: 1), in: unescaped) {
            let rawTitle = String(unescaped[titleRange])
            return unescapeXML(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Formats TimeInterval into UPnP time string (hh:mm:ss).
    public static func formatUPnPTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && !seconds.isNaN && seconds >= 0 else {
            return "00:00:00"
        }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    /// Formats bytes per second into human-readable network speed (e.g. 1.2 MB/s, 450 KB/s).
    public static func formatSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 && bytesPerSecond.isFinite else { return "0 KB/s" }
        if bytesPerSecond >= 1024 * 1024 {
            return String(format: "%.1f MB/s", bytesPerSecond / (1024 * 1024))
        } else {
            return String(format: "%.0f KB/s", bytesPerSecond / 1024)
        }
    }

    /// Parses UPnP time string (hh:mm:ss or mm:ss or seconds) into TimeInterval.
    public static func parseUPnPTime(_ timeString: String) -> TimeInterval {
        let parts = timeString.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").compactMap { Double($0) }
        if parts.count == 3 {
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
        } else if parts.count == 2 {
            return parts[0] * 60 + parts[1]
        } else if parts.count == 1 {
            return parts[0]
        }
        return 0
    }

    /// Wraps response parameters in standard UPnP SOAP Envelope XML.
    public static func makeSOAPResponse(actionName: String, serviceType: String, responseContent: String) -> String {
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:\(actionName)Response xmlns:u="\(serviceType)">
        \(responseContent)
            </u:\(actionName)Response>
          </s:Body>
        </s:Envelope>
        """
    }

    /// Escapes dynamic values before embedding them in an XML response.
    public static func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Generates UPnP SOAP Fault XML.
    public static func makeSOAPFault(errorCode: Int = 401, errorDescription: String = "Invalid Action") -> String {
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body>
            <s:Fault>
              <faultcode>s:Client</faultcode>
              <faultstring>UPnPError</faultstring>
              <detail>
                <UPnPError xmlns="urn:schemas-upnp-org:control-1-0">
                  <errorCode>\(errorCode)</errorCode>
                  <errorDescription>\(errorDescription)</errorDescription>
                </UPnPError>
              </detail>
            </s:Fault>
          </s:Body>
        </s:Envelope>
        """
    }

    public static func unescapeXML(_ string: String) -> String {
        var result = string
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")

        // Decode decimal numeric entities: &#(\d+);
        if let decRegex = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let matches = decRegex.matches(in: result, range: NSRange(location: 0, length: result.utf16.count)).reversed()
            for match in matches {
                guard let fullRange = Range(match.range(at: 0), in: result),
                      let numRange = Range(match.range(at: 1), in: result),
                      let codePoint = UInt32(result[numRange]),
                      let scalar = UnicodeScalar(codePoint) else { continue }
                result.replaceSubrange(fullRange, with: String(Character(scalar)))
            }
        }

        // Decode hexadecimal numeric entities: &#x([0-9a-fA-F]+);
        if let hexRegex = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);", options: .caseInsensitive) {
            let matches = hexRegex.matches(in: result, range: NSRange(location: 0, length: result.utf16.count)).reversed()
            for match in matches {
                guard let fullRange = Range(match.range(at: 0), in: result),
                      let numRange = Range(match.range(at: 1), in: result),
                      let codePoint = UInt32(result[numRange], radix: 16),
                      let scalar = UnicodeScalar(codePoint) else { continue }
                result.replaceSubrange(fullRange, with: String(Character(scalar)))
            }
        }

        return result
    }
}

// MARK: - XML SAX Parser for SOAP

private final class SOAPXMLHelper: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private var currentElement: String = ""
    private var currentValue: String = ""
    private var actionName: String = ""
    private var parameters: [String: String] = [:]
    private var depth = 0
    private var actionDepth = -1
    private var parentElements: [String] = []

    init(data: Data) {
        self.parser = XMLParser(data: data)
        super.init()
        self.parser.delegate = self
    }

    func parse() -> (actionName: String, parameters: [String: String]) {
        parser.parse()
        return (actionName, parameters)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        depth += 1
        let strippedParent = parentElements.last?.components(separatedBy: ":").last ?? ""
        parentElements.append(elementName)
        currentElement = elementName
        currentValue = ""

        // Elements inside Body are usually the action tag
        let strippedName = elementName.components(separatedBy: ":").last ?? elementName
        if depth == 3 && actionName.isEmpty && strippedParent == "Body"
           && strippedName != "Body" && strippedName != "Envelope" {
            actionName = strippedName
            actionDepth = depth
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) {
            currentValue += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let strippedName = elementName.components(separatedBy: ":").last ?? elementName
        if depth > actionDepth && actionDepth != -1 && !strippedName.isEmpty {
            parameters[strippedName] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !parentElements.isEmpty {
            parentElements.removeLast()
        }
        depth -= 1
    }
}
