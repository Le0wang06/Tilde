import Foundation

public struct LiveMetricSample: Equatable, Identifiable, Sendable {
    public let timestamp: Date
    public let cpuPercent: Double?
    public let memoryPercent: Double?
    public let downloadMbps: Double?
    public let uploadMbps: Double?

    public var id: Date { timestamp }

    public init(
        timestamp: Date,
        cpuPercent: Double?,
        memoryPercent: Double?,
        downloadMbps: Double?,
        uploadMbps: Double?
    ) {
        self.timestamp = timestamp
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
    }

    public init(snapshot: SystemSnapshot) {
        timestamp = snapshot.timestamp
        if case .available(let cpu) = snapshot.cpu {
            cpuPercent = cpu.usagePercent
        } else {
            cpuPercent = nil
        }
        if case .available(let memory) = snapshot.memory, memory.totalBytes > 0 {
            memoryPercent = Double(memory.usedBytes) / Double(memory.totalBytes) * 100
        } else {
            memoryPercent = nil
        }
        if case .available(let network) = snapshot.network {
            downloadMbps = network.downloadBytesPerSecond.map { $0 * 8 / 1_000_000 }
            uploadMbps = network.uploadBytesPerSecond.map { $0 * 8 / 1_000_000 }
        } else {
            downloadMbps = nil
            uploadMbps = nil
        }
    }
}

public struct LiveMetricHistory: Sendable {
    public let capacity: Int
    public private(set) var samples: [LiveMetricSample]

    public init(capacity: Int = 120, samples: [LiveMetricSample] = []) {
        self.capacity = max(1, capacity)
        self.samples = Array(samples.suffix(max(1, capacity)))
    }

    public mutating func append(_ sample: LiveMetricSample) {
        if samples.last?.timestamp == sample.timestamp {
            samples[samples.count - 1] = sample
            return
        }
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }
}
