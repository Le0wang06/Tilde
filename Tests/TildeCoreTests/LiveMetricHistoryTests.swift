import Foundation
import Testing
@testable import TildeCore

@Test func liveMetricHistoryKeepsNewestSamplesWithinCapacity() {
    var history = LiveMetricHistory(capacity: 2)
    history.append(sample(at: 1, cpu: 10))
    history.append(sample(at: 2, cpu: 20))
    history.append(sample(at: 3, cpu: 30))

    #expect(history.samples.map(\.cpuPercent) == [20, 30])
}

@Test func liveMetricHistoryReplacesDuplicateTimestamp() {
    var history = LiveMetricHistory(capacity: 2)
    history.append(sample(at: 1, cpu: 10))
    history.append(sample(at: 1, cpu: 25))

    #expect(history.samples.count == 1)
    #expect(history.samples.first?.cpuPercent == 25)
}

private func sample(at timestamp: TimeInterval, cpu: Double) -> LiveMetricSample {
    LiveMetricSample(
        timestamp: Date(timeIntervalSince1970: timestamp),
        cpuPercent: cpu,
        memoryPercent: nil,
        downloadMbps: nil,
        uploadMbps: nil
    )
}
