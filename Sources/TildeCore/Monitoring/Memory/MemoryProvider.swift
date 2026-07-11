import Darwin
import Dispatch
import Foundation

public enum MemoryPressureParser {
    public static func parseLevel(_ level: Int32) -> MemoryPressure {
        switch UInt(level) {
        case DispatchSource.MemoryPressureEvent.normal.rawValue: .normal
        case DispatchSource.MemoryPressureEvent.warning.rawValue: .warning
        case DispatchSource.MemoryPressureEvent.critical.rawValue: .critical
        default: .unavailable
        }
    }
}

public struct MemoryProvider: MetricProvider {
    public init() {}

    public func fetchSnapshot() async throws -> MemoryReading {
        try await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try Self.readMemory()
        }.value
    }

    private static func readMemory() throws -> MemoryReading {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw MetricError.systemCall("host_statistics64", code: Int32(result))
        }

        var hostPageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &hostPageSize) == KERN_SUCCESS else {
            throw MetricError.unavailable("Kernel page size is unavailable")
        }
        let pageSize = UInt64(hostPageSize)
        let total = ProcessInfo.processInfo.physicalMemory
        let freePages = UInt64(statistics.free_count + statistics.speculative_count)
        let freeBytes = min(total, freePages * pageSize)

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapResult = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        let swapUsed = swapResult == 0 ? UInt64(swap.xsu_used) : 0

        return MemoryReading(
            usedBytes: total - freeBytes,
            totalBytes: total,
            swapUsedBytes: swapUsed,
            pressure: readPressure()
        )
    }

    private static func readPressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .unavailable
        }
        return MemoryPressureParser.parseLevel(level)
    }
}
