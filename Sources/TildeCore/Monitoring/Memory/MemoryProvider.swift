import Darwin
import Foundation

public enum MemoryPressureParser {
    public static func parse(_ output: String) -> MemoryPressure {
        let normalized = output.lowercased()
        if normalized.contains("critical") { return .critical }
        if normalized.contains("warn") { return .warning }
        if normalized.contains("normal") || normalized.contains("free percentage") { return .normal }
        return .unavailable
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
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/memory_pressure")
        process.arguments = ["-Q"]
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return .unavailable }
            return MemoryPressureParser.parse(String(decoding: data, as: UTF8.self))
        } catch {
            return .unavailable
        }
    }
}
