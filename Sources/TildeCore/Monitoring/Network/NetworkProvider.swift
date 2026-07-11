import Darwin
import Foundation

public struct NetworkCounters: Equatable, Sendable {
    public let receivedBytes: UInt64
    public let sentBytes: UInt64

    public init(receivedBytes: UInt64, sentBytes: UInt64) {
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
    }
}

public enum NetworkRateCalculator {
    public static func rates(
        previous: NetworkCounters,
        current: NetworkCounters,
        elapsed: TimeInterval
    ) -> (download: Double, upload: Double)? {
        guard elapsed > 0,
              current.receivedBytes >= previous.receivedBytes,
              current.sentBytes >= previous.sentBytes else { return nil }
        return (
            Double(current.receivedBytes - previous.receivedBytes) / elapsed,
            Double(current.sentBytes - previous.sentBytes) / elapsed
        )
    }
}

public actor NetworkProvider: MetricProvider {
    private var previous: (counters: NetworkCounters, date: Date)?

    public init() {}

    public func fetchSnapshot() async throws -> NetworkReading {
        try Task.checkCancellation()
        var current = try readInterfaces()
        var now = Date()

        if previous == nil {
            previous = (current.counters, now)
            try await Task.sleep(for: .milliseconds(250))
            try Task.checkCancellation()
            current = try readInterfaces()
            now = Date()
        }

        let rates = previous.flatMap {
            NetworkRateCalculator.rates(previous: $0.counters, current: current.counters, elapsed: now.timeIntervalSince($0.date))
        }
        previous = (current.counters, now)

        return NetworkReading(
            downloadBytesPerSecond: rates?.download,
            uploadBytesPerSecond: rates?.upload,
            localIPAddress: current.address,
            interfaceName: current.interfaceName
        )
    }

    private func readInterfaces() throws -> (counters: NetworkCounters, address: String?, interfaceName: String?) {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            throw MetricError.systemCall("getifaddrs", code: errno)
        }
        defer { freeifaddrs(pointer) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var selectedAddress: String?
        var selectedName: String?
        var current: UnsafeMutablePointer<ifaddrs>? = first

        while let entry = current?.pointee {
            let flags = Int32(entry.ifa_flags)
            let isUp = flags & IFF_UP != 0
            let isLoopback = flags & IFF_LOOPBACK != 0
            let name = String(cString: entry.ifa_name)

            if isUp && !isLoopback {
                if entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), let dataPointer = entry.ifa_data {
                    let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
                    received += UInt64(data.ifi_ibytes)
                    sent += UInt64(data.ifi_obytes)
                }

                if selectedAddress == nil,
                   entry.ifa_addr?.pointee.sa_family == UInt8(AF_INET),
                   name.hasPrefix("en") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let result = getnameinfo(
                        entry.ifa_addr,
                        socklen_t(entry.ifa_addr.pointee.sa_len),
                        &host,
                        socklen_t(host.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    if result == 0 {
                        let bytes = host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
                        selectedAddress = String(decoding: bytes, as: UTF8.self)
                        selectedName = name
                    }
                }
            }
            current = entry.ifa_next
        }

        return (NetworkCounters(receivedBytes: received, sentBytes: sent), selectedAddress, selectedName)
    }
}
