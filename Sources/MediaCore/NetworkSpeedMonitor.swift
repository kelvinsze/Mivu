import Foundation
import Darwin

/// Monitors real-time network download throughput across all active network interfaces (Wi-Fi, Cellular).
public enum NetworkSpeedMonitor {
    private static var lastBytes: UInt64 = 0
    private static var lastCheckTime: Date = Date()
    private static var currentSpeedCache: Double = 0

    /// Returns the current incoming download rate in Bytes per second.
    public static func currentDownloadSpeed() -> Double {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return currentSpeedCache
        }
        defer { freeifaddrs(ifaddr) }

        var totalBytes: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            if isUp && !isLoopback, let addr = current.pointee.ifa_addr {
                if addr.pointee.sa_family == UInt8(AF_LINK) {
                    if let data = current.pointee.ifa_data {
                        let ifData = data.assumingMemoryBound(to: if_data.self)
                        totalBytes += UInt64(ifData.pointee.ifi_ibytes)
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }

        let now = Date()
        let interval = now.timeIntervalSince(lastCheckTime)
        guard interval >= 0.35 else {
            return currentSpeedCache
        }

        let deltaBytes = totalBytes >= lastBytes ? totalBytes - lastBytes : 0
        let speed = (lastBytes > 0 && interval > 0) ? (Double(deltaBytes) / interval) : 0

        lastBytes = totalBytes
        lastCheckTime = now
        currentSpeedCache = speed
        return speed
    }

    public static func reset() {
        lastBytes = 0
        lastCheckTime = Date()
        currentSpeedCache = 0
    }
}
