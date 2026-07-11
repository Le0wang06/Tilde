import Foundation

public struct StorageProvider: MetricProvider {
    private let volumeURL: URL

    public init(volumeURL: URL = URL(fileURLWithPath: "/")) {
        self.volumeURL = volumeURL
    }

    public func fetchSnapshot() async throws -> StorageReading {
        try Task.checkCancellation()
        let values = try volumeURL.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])

        guard let totalValue = values.volumeTotalCapacity,
              let availableValue = values.volumeAvailableCapacityForImportantUsage else {
            throw MetricError.unavailable("Volume capacity keys are unavailable")
        }

        let total = UInt64(max(0, totalValue))
        let available = UInt64(max(0, availableValue))
        return StorageReading(usedBytes: total - min(total, available), totalBytes: total)
    }
}
