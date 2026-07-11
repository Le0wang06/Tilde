import Darwin
import Foundation

public struct CPUTickSnapshot: Equatable, Sendable {
    public let user: UInt64
    public let system: UInt64
    public let idle: UInt64
    public let nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

public enum CPUUsageCalculator {
    public static func usagePercent(from previous: CPUTickSnapshot, to current: CPUTickSnapshot) -> Double? {
        let previousTotal = previous.user + previous.system + previous.idle + previous.nice
        let currentTotal = current.user + current.system + current.idle + current.nice
        guard currentTotal > previousTotal, current.idle >= previous.idle else { return nil }

        let totalDelta = currentTotal - previousTotal
        let idleDelta = current.idle - previous.idle
        return min(100, max(0, Double(totalDelta - idleDelta) / Double(totalDelta) * 100))
    }
}

public actor CPUProvider: MetricProvider {
    private var previousTicks: CPUTickSnapshot?

    public init() {}

    public func fetchSnapshot() async throws -> CPUReading {
        try Task.checkCancellation()
        let current = try readTicks()

        if let previousTicks, let usage = CPUUsageCalculator.usagePercent(from: previousTicks, to: current) {
            self.previousTicks = current
            return CPUReading(usagePercent: usage)
        }

        previousTicks = current
        try await Task.sleep(for: .milliseconds(250))
        try Task.checkCancellation()
        let next = try readTicks()
        self.previousTicks = next

        guard let usage = CPUUsageCalculator.usagePercent(from: current, to: next) else {
            throw MetricError.unavailable("CPU counters did not advance")
        }
        return CPUReading(usagePercent: usage)
    }

    private func readTicks() throws -> CPUTickSnapshot {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            throw MetricError.systemCall("host_statistics", code: Int32(result))
        }

        return CPUTickSnapshot(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }
}
