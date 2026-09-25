import SwiftUI
import Network

/// Enhanced diagnostics dashboard for network routing, SSDP inspector, Web Remote, and loopback casting.
public struct DiagnosticsView: View {
    @State private var localIP = HTTPServer.shared.localIPAddress
    @State private var interfaces: [NetworkInterfaceInfo] = []
    @State private var diagnosticLog: [String] = []
    @State private var isRunningTest = false
    @State private var probeUrlInput = "https://v-cdn.zjol.com.cn/280443.mp4"
    @State private var probeResult: String?
    @State private var isProbing = false
    @State private var playbackLogsOnly = false

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                // MARK: - Web Remote Access
                Section("Web Remote & Casting Link") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Open this link on any phone, tablet, or Mac on the same Wi-Fi to push video URLs or control CarPlay:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        let webUrl = "http://\(localIP):\(HTTPServer.shared.port)/web#access-code=\(HTTPServer.shared.webAccessCode)"
                        HStack {
                            Text(verbatim: webUrl)
                                .font(.subheadline.monospaced())
                                .foregroundColor(.cyan)

                            Spacer()

                            Button {
                                UIPasteboard.general.string = webUrl
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            if let url = URL(string: webUrl) {
                                Link(destination: url) {
                                    Image(systemName: "safari")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // MARK: - Active Network Interfaces
                Section("Active Network Interfaces") {
                    ForEach(interfaces) { iface in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(iface.name)
                                    .font(.subheadline.bold())
                                Text(iface.type)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(iface.ipAddress)
                                .font(.subheadline.monospaced())
                        }
                    }

                    if interfaces.isEmpty {
                        Text("No active interfaces detected.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                // MARK: - Stream Probe & Header Inspector
                Section("URL Stream Probe & ATS Test") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Video URL to probe", text: $probeUrlInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .autocapitalization(.none)

                        Button {
                            probeStreamURL()
                        } label: {
                            HStack {
                                if isProbing {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "network")
                                }
                                Text("Probe HTTP Headers & Status")
                            }
                        }
                        .disabled(isProbing || probeUrlInput.trimmingCharacters(in: .whitespaces).isEmpty)

                        if let result = probeResult {
                            Text(verbatim: result)
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                                .padding(8)
                                .background(Color(.tertiarySystemBackground))
                                .cornerRadius(6)
                        }
                    }
                }

                // MARK: - Receiver & SSDP Control
                Section("Receiver & SSDP Inspector") {
                    HStack {
                        Text("HTTP Server")
                        Spacer()
                        Text(":\(HTTPServer.shared.port)")
                            .foregroundColor(.green)
                    }

                    HStack {
                        Text("SSDP Multicast")
                        Spacer()
                        Text("239.255.255.250:1900")
                            .font(.caption.monospaced())
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Active Discovery Paths")
                            .font(.subheadline)
                        Text("Multicast · Broadcast · Loopback multicast/unicast · Local-address unicast")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let lastPath = UserDefaults.standard.string(forKey: "mivu_last_successful_cast_path") {
                        HStack {
                            Text("Last Media-Ready Path")
                            Spacer()
                            Text(verbatim: lastPath)
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }

                    Button {
                        SSDPService.shared.sendAllDiscoveryAnnouncements()
                    } label: {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text("Send All Discovery Announcements")
                        }
                    }

                    Button {
                        runLoopbackTest()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Run Local Loopback SOAP Test")
                        }
                    }
                    .disabled(isRunningTest)
                }

                // MARK: - Live Diagnostic Log
                Section("Live Event Log") {
                    Toggle("仅显示播放诊断", isOn: $playbackLogsOnly)
                    Button(playbackLogsOnly ? "复制播放诊断日志" : "复制完整诊断日志", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = visibleDiagnosticLogs.reversed().joined(separator: "\n")
                    }
                    Button("清空诊断日志", systemImage: "trash", role: .destructive) {
                        diagnosticLog.removeAll()
                        SSDPService.shared.clearDiagnosticHistory()
                    }
                    if diagnosticLog.isEmpty {
                        Text("No diagnostic events yet.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(Array(visibleDiagnosticLogs.prefix(200).enumerated()), id: \.offset) { _, log in
                            Text(verbatim: log)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Diagnostics")
            .onAppear {
                refreshInterfaces()
                setupSSDPListener()
            }
        }
    }

    private func refreshInterfaces() {
        localIP = HTTPServer.shared.localIPAddress
        var results: [NetworkInterfaceInfo] = []

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(
                    interface.ifa_addr,
                    socklen_t(interface.ifa_addr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                let ip = String(cString: hostname)
                let type: String
                if name.hasPrefix("en") { type = "Wi-Fi / Ethernet" }
                else if name.hasPrefix("pdp_ip") { type = "Cellular" }
                else if name.hasPrefix("lo") { type = "Loopback" }
                else { type = "Other" }

                results.append(NetworkInterfaceInfo(name: name, type: type, ipAddress: ip))
            }
        }
        self.interfaces = results
    }

    private func setupSSDPListener() {
        SSDPService.shared.onDiscoveryEvent = { event in
            Task { @MainActor in
                self.addReceiverLog(event)
            }
        }
        SSDPService.shared.requestDiagnosticHistory { events in
            Task { @MainActor in
                for event in events.reversed() {
                    self.addReceiverLog(event)
                }
            }
        }
    }

    private func probeStreamURL() {
        guard let url = URL(string: probeUrlInput.trimmingCharacters(in: .whitespaces)) else { return }
        isProbing = true
        probeResult = nil

        Task {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 8

            let startTime = CFAbsoluteTimeGetCurrent()
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                if let httpResp = response as? HTTPURLResponse {
                    let type = httpResp.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                    let length = httpResp.value(forHTTPHeaderField: "Content-Length") ?? "chunked/unknown"
                    probeResult = "HTTP \(httpResp.statusCode) OK (\(elapsedMs)ms)\nType: \(type)\nLength: \(length)"
                    addLog("Probe \(url.host ?? ""): HTTP \(httpResp.statusCode) (\(elapsedMs)ms)")
                }
            } catch {
                probeResult = "Probe Error: \(error.localizedDescription)"
                addLog("Probe failed: \(error.localizedDescription)")
            }
            isProbing = false
        }
    }

    private func runLoopbackTest() {
        isRunningTest = true
        addLog("Starting local loopback SOAP test...")

        Task {
            let startTime = CFAbsoluteTimeGetCurrent()
            let url = URL(string: "http://127.0.0.1:\(HTTPServer.shared.port)/upnp/control/avtransport")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
            request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#GetTransportInfo\"", forHTTPHeaderField: "SOAPACTION")

            let soapBody = """
            <?xml version="1.0" encoding="utf-8"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
              <s:Body>
                <u:GetTransportInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
                  <InstanceID>0</InstanceID>
                </u:GetTransportInfo>
              </s:Body>
            </s:Envelope>
            """
            request.httpBody = Data(soapBody.utf8)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let latencyMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                if let httpResponse = response as? HTTPURLResponse {
                    addLog("Loopback HTTP \(httpResponse.statusCode) OK (\(latencyMs)ms)")
                    if let str = String(data: data, encoding: .utf8) {
                        addLog("SOAP Response: \(str.replacingOccurrences(of: "\n", with: " ").prefix(80))...")
                    }
                }
            } catch {
                addLog("Loopback test failed: \(error.localizedDescription)")
            }

            isRunningTest = false
        }
    }

    private func addLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        diagnosticLog.insert("[\(timestamp)] \(message)", at: 0)
    }

    private var visibleDiagnosticLogs: [String] {
        diagnosticLog.filter {
            !playbackLogsOnly || $0.contains("[DEBUG-playback]") || $0.contains("[DEBUG-cast]")
        }
    }

    private func addReceiverLog(_ entry: String) {
        // History already carries the event's original timestamp, not the time this view opens.
        guard !diagnosticLog.contains(entry) else { return }
        diagnosticLog.insert(entry, at: 0)
        if diagnosticLog.count > 400 { diagnosticLog.removeLast(diagnosticLog.count - 400) }
    }
}

public struct NetworkInterfaceInfo: Identifiable, Sendable {
    public var id: String { "\(name)_\(ipAddress)" }
    public let name: String
    public let type: String
    public let ipAddress: String

    public init(name: String, type: String, ipAddress: String) {
        self.name = name
        self.type = type
        self.ipAddress = ipAddress
    }
}
