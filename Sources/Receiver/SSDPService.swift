import Foundation
import Network
import OSLog
import Combine

private let logger = Logger(subsystem: "com.kold.mivu", category: "SSDPService")

/// Robust multi-tiered SSDP (Simple Service Discovery Protocol) & Bonjour broadcaster.
/// Supports POSIX UDP Socket, NWConnectionGroup, Subnet Broadcasts, and mDNS announcements.
public final class SSDPService: NSObject, @unchecked Sendable, NetServiceDelegate {
    public static let shared = SSDPService()

    public enum DiscoveryPath: String, Sendable {
        case bsdMulticast = "BSD 组播/广播"
        case networkFramework = "Network.framework 组播"
        case loopbackMulticast = "本机回环组播"
        case loopbackUnicast = "本机回环单播"
        case localAddressUnicast = "本机地址单播"
        case unknown = "未知路径"
    }

    private let multicastIP = "239.255.255.250"
    private let multicastPort: UInt16 = 1900
    private let queue = DispatchQueue(label: "com.kold.mivu.ssdp", qos: .userInitiated)

    private var connectionGroup: NWConnectionGroup?
    private var isRunning = false
    private var advertiseTimer: DispatchSourceTimer?
    private var bsdSocketFD: Int32 = -1
    private var bsdReadSource: DispatchSourceRead?
    private var upnpNetService: NetService?
    private var recentDiagnosticEvents: [String] = []
    private var discoveryPathByRemoteHost: [String: DiscoveryPath] = [:]
    private var pendingCastPath: DiscoveryPath?
    private var pathMonitor: NWPathMonitor?
    private var interfaceSignature = ""

    // Recent discovery logs for Diagnostics
    public var onDiscoveryEvent: ((String) -> Void)?

    public static func discoveryPath(forRemoteHost remoteHost: String, knownPath: DiscoveryPath? = nil) -> DiscoveryPath {
        if let knownPath { return knownPath }
        if remoteHost == "127.0.0.1" || remoteHost == "::1" { return .loopbackUnicast }
        if NetworkHelper.activeIPv4Interfaces().contains(where: { $0.address == remoteHost }) {
            return .localAddressUnicast
        }
        return .unknown
    }

    public static func discoveryPath(forHint hint: String?) -> DiscoveryPath? {
        switch hint {
        case "bsd-msearch", "bsd-notify": .bsdMulticast
        case "nw-msearch", "nw-notify": .networkFramework
        case "loopback-multicast": .loopbackMulticast
        case "loopback-unicast": .loopbackUnicast
        case "local-address": .localAddressUnicast
        default: nil
        }
    }

    public static func parseMSearchTarget(_ packet: String) -> String? {
        let lines = packet.components(separatedBy: "\r\n")
        guard let firstLine = lines.first, firstLine.uppercased().hasPrefix("M-SEARCH") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { headers[parts[0].uppercased()] = parts[1] }
        }
        guard let man = headers["MAN"], man.lowercased().contains("ssdp:discover") else { return nil }
        return headers["ST"]
    }

    public static func targetTypes(for udn: String) -> [(st: String, usn: String)] {
        [("upnp:rootdevice", "\(udn)::upnp:rootdevice"), (udn, udn),
         ("urn:schemas-upnp-org:device:MediaRenderer:1", "\(udn)::urn:schemas-upnp-org:device:MediaRenderer:1"),
         ("urn:schemas-upnp-org:service:AVTransport:1", "\(udn)::urn:schemas-upnp-org:service:AVTransport:1"),
         ("urn:schemas-upnp-org:service:RenderingControl:1", "\(udn)::urn:schemas-upnp-org:service:RenderingControl:1"),
         ("urn:schemas-upnp-org:service:ConnectionManager:1", "\(udn)::urn:schemas-upnp-org:service:ConnectionManager:1")]
    }

    public static func mSearchResponses(for st: String, udn: String, location: String, date: String) -> [Data] {
        targetTypes(for: udn).compactMap { target in
            guard st == "ssdp:all" || st == target.st else { return nil }
            return "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nDATE: \(date)\r\nEXT:\r\nLOCATION: \(location)\r\nSERVER: iOS/17 UPnP/1.0 Mivu/0.1\r\nST: \(target.st)\r\nUSN: \(target.usn)\r\nBOOTID.UPNP.ORG: 1\r\n\r\n".data(using: .utf8)
        }
    }

    public static func descriptionLocation(host: String, port: UInt16) -> String {
        // A device must not appear to move whenever a different discovery path wins.
        "http://\(host):\(port)/description.xml"
    }

    public static func responseHost(remoteHost: String, localAddresses: [String], routeAddress: String?, fallbackAddress: String) -> String {
        if remoteHost.hasPrefix("127.") { return "127.0.0.1" }
        if localAddresses.contains(remoteHost) { return remoteHost }
        return routeAddress ?? fallbackAddress
    }

    private override init() {
        super.init()
    }

    public func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    private func startOnQueue() {
        guard !isRunning else { return }
        isRunning = true
        logger.info("Starting Multi-Tier SSDP & Bonjour Service...")
        emitDiagnostic("[已启用] BSD/NW 组播 + 广播 + 本机回环组播/单播 + 本机地址单播")

        // 1. Start POSIX BSD UDP Multicast Socket listener on port 1900
        startBSDSocketListener()

        // 2. Start NWConnectionGroup (Network.framework)
        startNWConnectionGroup()

        // 3. Start Bonjour / mDNS publication
        startBonjourAnnouncement()

        // 4. Start periodic advertising timer (frequent initial bursts, then periodic)
        startAdvertisingTimer()

        // Send immediate SSDP alive announcements
        sendSSDPAlive()
        startNetworkMonitor()
    }

    public func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    private func stopOnQueue() {
        pathMonitor?.cancel()
        pathMonitor = nil
        advertiseTimer?.cancel()
        advertiseTimer = nil

        sendSSDPByeBye()

        stopBSDSocketListener()
        stopNWConnectionGroup()
        stopBonjourAnnouncement()

        isRunning = false
        logger.info("SSDP Service stopped.")
    }

    // MARK: - 1. POSIX BSD UDP Socket Listener (Multicast + Broadcast fallback)

    private func startBSDSocketListener() {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            logger.error("Failed to create BSD socket: \(errno)")
            return
        }

        var reuseOn: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseOn, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuseOn, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &reuseOn, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &reuseOn, socklen_t(MemoryLayout<Int32>.size))

        // Bind to INADDR_ANY:1900
        var bindAddr = sockaddr_in()
        bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = in_port_t(multicastPort).bigEndian
        bindAddr.sin_addr.s_addr = in_addr_t(0) // INADDR_ANY

        let bindResult = withUnsafePointer(to: &bindAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if bindResult < 0 {
            emitDiagnostic("[监听失败] UDP 1900 bind errno=\(errno)")
            close(fd)
            return
        }

        // Join on every active IPv4 interface, including lo0. INADDR_ANY only
        // follows the default route and stops covering same-device discovery
        // when ordinary Wi-Fi is disabled.
        var membershipAddresses = Set(NetworkHelper.activeIPv4Interfaces().map(\.address))
        if membershipAddresses.isEmpty { membershipAddresses.insert("0.0.0.0") }
        for address in membershipAddresses {
            var mreq = ip_mreq()
            mreq.imr_multiaddr.s_addr = inet_addr(multicastIP)
            mreq.imr_interface.s_addr = inet_addr(address)
            let result = setsockopt(
                fd,
                IPPROTO_IP,
                IP_ADD_MEMBERSHIP,
                &mreq,
                socklen_t(MemoryLayout<ip_mreq>.size)
            )
            if result == 0 {
                emitDiagnostic("[监听已加入] SSDP multicast via \(address)")
            } else {
                emitDiagnostic("[监听加入失败] SSDP multicast via \(address), errno=\(errno)")
            }
        }

        self.bsdSocketFD = fd

        // Read source via DispatchSource
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleBSDSocketReadable()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        self.bsdReadSource = source
        logger.info("BSD POSIX UDP Socket listener active on port 1900.")
    }

    private func handleBSDSocketReadable() {
        guard bsdSocketFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let bytesRead = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(bsdSocketFD, &buffer, buffer.count, 0, $0, &addrLen)
            }
        }

        guard bytesRead > 0 else { return }
        if let packet = String(bytes: buffer[0..<bytesRead], encoding: .utf8) {
            processIncomingPacket(packet, clientAddr: clientAddr)
        }
    }

    private func processIncomingPacket(_ packet: String, clientAddr: sockaddr_in) {
        guard let st = Self.parseMSearchTarget(packet) else { return }

        let remoteHost = Self.ipv4String(from: clientAddr)
        let path: DiscoveryPath = remoteHost == "127.0.0.1" ? .loopbackUnicast : .bsdMulticast
        discoveryPathByRemoteHost[remoteHost] = path
        emitDiagnostic("[发现][\(path.rawValue)] M-SEARCH \(st) from \(remoteHost):\(UInt16(bigEndian: clientAddr.sin_port))")

        respondToMSearchViaBSDSocket(st: st, clientAddr: clientAddr)
    }

    private func respondToMSearchViaBSDSocket(st: String, clientAddr: sockaddr_in) {
        let device = UPnPDevice.shared
        let ip = responseHost(for: clientAddr)
        let port = HTTPServer.shared.port
        let location = Self.descriptionLocation(host: ip, port: port)


        var targetAddr = clientAddr
        let responses = Self.mSearchResponses(for: st, udn: device.udn, location: location, date: httpDateString())
        var sent = 0
        for data in responses where bsdSocketFD >= 0 {
            let result = data.withUnsafeBytes { rawPtr in
                withUnsafePointer(to: &targetAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(bsdSocketFD, rawPtr.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if result == data.count { sent += 1 }
        }
        emitDiagnostic("[发现回复][BSD] \(sent)/\(responses.count) ST=\(st) LOCATION=\(location)")
    }

    private func responseHost(for peer: sockaddr_in) -> String {
        let remoteHost = Self.ipv4String(from: peer)
        var routeAddress: String?
        // UDP connect selects a route without transmitting a packet. Unlike one global
        // Wi-Fi/cellular address, getsockname reflects the route back to this controller.
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if fd >= 0 {
            defer { close(fd) }
            var destination = peer
            let result = withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result == 0 {
                var local = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let found = withUnsafeMutablePointer(to: &local) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
                }
                if found == 0, local.sin_addr.s_addr != 0 { routeAddress = Self.ipv4String(from: local) }
            }
        }
        return Self.responseHost(remoteHost: remoteHost, localAddresses: NetworkHelper.activeIPv4Interfaces().map(\.address), routeAddress: routeAddress, fallbackAddress: HTTPServer.shared.localIPAddress)
    }

    private func stopBSDSocketListener() {
        bsdReadSource?.cancel()
        bsdReadSource = nil
        bsdSocketFD = -1
    }

    // MARK: - 2. NWConnectionGroup

    private func startNWConnectionGroup() {
        guard let group = try? NWMulticastGroup(for: [.hostPort(host: .init(multicastIP), port: .init(integerLiteral: multicastPort))]) else {
            return
        }

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        let connectionGroup = NWConnectionGroup(with: group, using: params)
        connectionGroup.setReceiveHandler(maximumMessageSize: 4096, rejectOversizedMessages: true) { [weak self] message, content, isComplete in
            if let content = content, let text = String(data: content, encoding: .utf8) {
                self?.handleNWPacket(text, message: message)
            }
        }

        connectionGroup.stateUpdateHandler = { state in
            switch state {
            case .ready:
                logger.info("NWConnectionGroup ready.")
            case .failed(let error):
                logger.debug("NWConnectionGroup failed: \(error.localizedDescription)")
            default:
                break
            }
        }

        connectionGroup.start(queue: queue)
        self.connectionGroup = connectionGroup
    }

    private func handleNWPacket(_ packet: String, message: NWConnectionGroup.Message) {
        guard let st = Self.parseMSearchTarget(packet) else { return }
        let remoteHost = Self.hostString(from: message.remoteEndpoint)
        discoveryPathByRemoteHost[remoteHost] = .networkFramework
        emitDiagnostic("[发现][\(DiscoveryPath.networkFramework.rawValue)] M-SEARCH \(st) from \(remoteHost)")

        let device = UPnPDevice.shared
        var peer = sockaddr_in()
        peer.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        peer.sin_family = sa_family_t(AF_INET)
        peer.sin_addr.s_addr = inet_addr(remoteHost)
        peer.sin_port = multicastPort.bigEndian
        let ip = responseHost(for: peer)
        let port = HTTPServer.shared.port
        let location = Self.descriptionLocation(host: ip, port: port)


        let responses = Self.mSearchResponses(for: st, udn: device.udn, location: location, date: httpDateString())
        for data in responses {
            message.reply(content: data)
        }
        emitDiagnostic("[发现回复][NW] \(responses.count) ST=\(st) LOCATION=\(location)")
    }

    private func stopNWConnectionGroup() {
        connectionGroup?.cancel()
        connectionGroup = nil
    }

    // MARK: - 3. Bonjour / mDNS Service

    private func startBonjourAnnouncement() {
        let name = UPnPDevice.shared.friendlyName
        let port = Int32(HTTPServer.shared.port)
        let netService = NetService(domain: "local.", type: "_upnp._tcp.", name: name, port: port)
        netService.delegate = self
        netService.schedule(in: .main, forMode: .common)
        netService.publish(options: [])
        self.upnpNetService = netService
    }

    private func stopBonjourAnnouncement() {
        upnpNetService?.stop()
        upnpNetService?.remove(from: .main, forMode: .common)
        upnpNetService = nil
    }

    // MARK: - 4. Subnet & Multicast Active NOTIFY Broadcasts

    private func startAdvertisingTimer() {
        advertiseTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Repeat every 5 seconds for snappy local network discovery
        timer.schedule(deadline: .now() + 1, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.sendSSDPAlive()
        }
        timer.resume()
        self.advertiseTimer = timer
    }

    public func sendSSDPAlive() {
        sendNotification(nts: "ssdp:alive")
    }

    public func sendAllDiscoveryAnnouncements() {
        queue.async { [weak self] in
            self?.emitDiagnostic("[手动宣告] 同时发送全部非 VPN 发现路径")
            self?.sendSSDPAlive()
        }
    }

    private func startNetworkMonitor() {
        interfaceSignature = currentInterfaceSignature()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            guard let self, self.isRunning else { return }
            let signature = self.currentInterfaceSignature()
            guard signature != self.interfaceSignature else { return }
            self.interfaceSignature = signature
            self.emitDiagnostic("[网络变化] 重建发现监听：\(signature)")
            self.stopBSDSocketListener()
            self.stopNWConnectionGroup()
            self.startBSDSocketListener()
            self.startNWConnectionGroup()
            self.sendSSDPAlive()
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    private func currentInterfaceSignature() -> String {
        NetworkHelper.activeIPv4Interfaces().map { "\($0.name)=\($0.address)" }.sorted().joined(separator: ",")
    }

    public func sendSSDPByeBye() {
        sendNotification(nts: "ssdp:byebye")
    }

    private func sendNotification(nts: String) {
        let device = UPnPDevice.shared
        let port = HTTPServer.shared.port
        let loopbackLocation = Self.descriptionLocation(host: "127.0.0.1", port: port)
        let interfaces = NetworkHelper.activeIPv4Interfaces()
        let targetTypes = Self.targetTypes(for: device.udn).map { (nt: $0.st, usn: $0.usn) }

        for target in targetTypes {
            guard let loopbackData = notificationData(for: target, nts: nts, location: loopbackLocation) else { continue }

            // Same-device compatibility paths used when no ordinary Wi-Fi LAN exists.
            // The multicast packet is explicitly bound to lo0, so its loopback LOCATION
            // is never advertised to physical-network peers.
            sendMulticastBytes(loopbackData, interfaceAddress: "127.0.0.1")
            sendEphemeralUDPBytes(loopbackData, toIP: "127.0.0.1", port: multicastPort)

            for interface in interfaces
            where interface.address != "127.0.0.1" && !interface.name.hasPrefix("utun") {
                let localLocation = Self.descriptionLocation(host: interface.address, port: port)
                if let localData = notificationData(for: target, nts: nts, location: localLocation) {
                    sendEphemeralUDPBytes(localData, toIP: interface.address, port: multicastPort)
                    if !interface.name.hasPrefix("pdp_ip") {
                        sendMulticastBytes(localData, interfaceAddress: interface.address)
                        if interface.address == HTTPServer.shared.localIPAddress {
                            // Keep the existing Network.framework/broadcast fallback,
                            // but advertise the same stable URL as the BSD path.
                            connectionGroup?.send(content: localData) { _ in }
                            sendUDPBytes(localData, toIP: "255.255.255.255", port: multicastPort)
                        }
                    }
                }
            }
        }
    }

    private func notificationData(
        for target: (nt: String, usn: String),
        nts: String,
        location: String
    ) -> Data? {
        """
        NOTIFY * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        CACHE-CONTROL: max-age=1800\r
        LOCATION: \(location)\r
        NT: \(target.nt)\r
        NTS: \(nts)\r
        SERVER: iOS/17 UPnP/1.0 Mivu/0.1\r
        USN: \(target.usn)\r
        BOOTID.UPNP.ORG: 1\r
        \r\n
        """.data(using: .utf8)
    }

    private func sendUDPBytes(_ data: Data, toIP: String, port: UInt16) {
        guard bsdSocketFD >= 0 else { return }
        sendUDPBytes(data, socketFD: bsdSocketFD, toIP: toIP, port: port)
    }

    private func sendEphemeralUDPBytes(_ data: Data, toIP: String, port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        sendUDPBytes(data, socketFD: fd, toIP: toIP, port: port)
    }

    private func sendMulticastBytes(_ data: Data, interfaceAddress: String) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var enabled: Int32 = 1
        var outgoingAddress = in_addr(s_addr: inet_addr(interfaceAddress))
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &enabled, socklen_t(MemoryLayout<Int32>.size))
        guard setsockopt(
            fd,
            IPPROTO_IP,
            IP_MULTICAST_IF,
            &outgoingAddress,
            socklen_t(MemoryLayout<in_addr>.size)
        ) == 0 else { return }

        sendUDPBytes(data, socketFD: fd, toIP: multicastIP, port: multicastPort)
    }

    private func sendUDPBytes(_ data: Data, socketFD: Int32, toIP: String, port: UInt16) {
        var targetAddr = sockaddr_in()
        targetAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        targetAddr.sin_family = sa_family_t(AF_INET)
        targetAddr.sin_port = in_port_t(port).bigEndian
        targetAddr.sin_addr.s_addr = inet_addr(toIP)

        data.withUnsafeBytes { rawPtr in
            _ = withUnsafePointer(to: &targetAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketFD, rawPtr.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    public func recordHTTPStage(_ stage: String, remoteEndpoint: NWEndpoint?, discoveryHint: String? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let remoteHost = Self.hostString(from: remoteEndpoint)
            if let hintedPath = Self.discoveryPath(forHint: discoveryHint) {
                self.discoveryPathByRemoteHost[remoteHost] = hintedPath
            }
            let path = Self.discoveryPath(
                forRemoteHost: remoteHost,
                knownPath: self.discoveryPathByRemoteHost[remoteHost]
            )
            if stage == "SetAVTransportURI" {
                self.pendingCastPath = path
                self.emitDiagnostic("[控制已接收][\(path.rawValue)] \(stage) from \(remoteHost)")
            } else {
                self.emitDiagnostic("[回连][\(path.rawValue)] \(stage) from \(remoteHost)")
            }
        }
    }

    public func recordPlaybackStage(_ stage: String, successful: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            let path = self.pendingCastPath ?? .unknown
            if successful {
                UserDefaults.standard.set(path.rawValue, forKey: "mivu_last_successful_cast_path")
            }
            self.emitDiagnostic("[播放\(successful ? "成功" : "链路")][\(path.rawValue)] \(stage)")
        }
    }

    public func requestDiagnosticHistory(_ completion: @escaping @Sendable ([String]) -> Void) {
        queue.async { [weak self] in
            completion(self?.recentDiagnosticEvents ?? [])
        }
    }

    public func clearDiagnosticHistory() {
        queue.async { [weak self] in self?.recentDiagnosticEvents.removeAll() }
    }

    private func emitDiagnostic(_ event: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = "[\(timestamp)] \(event)"
        logger.info("\(entry, privacy: .public)")
        recentDiagnosticEvents.insert(entry, at: 0)
        if recentDiagnosticEvents.count > 400 {
            recentDiagnosticEvents.removeLast(recentDiagnosticEvents.count - 400)
        }
        onDiscoveryEvent?(entry)
    }

    /// Temporary, targeted trace for the real two-second restart (no signed URLs or credentials).
    public func recordCastDebug(_ message: String) {
        queue.async { [weak self] in self?.emitDiagnostic("[DEBUG-cast] \(message)") }
    }

    /// Playback trace shared by Emby/Jellyfin resolution and concrete player engines.
    /// Callers must pass only sanitized URLs; tokens, cookies, and header values are forbidden.
    public func recordPlaybackDebug(_ message: String) {
        queue.async { [weak self] in self?.emitDiagnostic("[DEBUG-playback] \(message)") }
    }

    public static func sanitizedPlaybackURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "invalid-url"
        }
        let queryNames = components.queryItems?.map(\.name).sorted() ?? []
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        let base = components.string ?? "invalid-url"
        return queryNames.isEmpty ? base : "\(base)?keys=\(queryNames.joined(separator: ","))"
    }

    private static func ipv4String(from address: sockaddr_in) -> String {
        var sinAddress = address.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &sinAddress, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return "unknown"
        }
        return String(cString: buffer)
    }

    private static func hostString(from endpoint: NWEndpoint?) -> String {
        guard case let .hostPort(host, _) = endpoint else { return "unknown" }
        return String(describing: host)
    }

    private func httpDateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date())
    }
}
