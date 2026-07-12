import Foundation
import Testing
@testable import TildeCore

@Test func adaptivePolicyUsesMetricSpecificForegroundIntervals() {
    let policy = AdaptiveSamplingPolicy.standard
    let start = Date(timeIntervalSince1970: 1_000)
    let sampled = Dictionary(uniqueKeysWithValues: LiveMetric.allCases.map { ($0, start) })

    let afterOneSecond = policy.dueMetrics(
        lastSampled: sampled,
        now: start.addingTimeInterval(1),
        isForeground: true
    )
    #expect(afterOneSecond.contains(.cpu))
    #expect(afterOneSecond.contains(.network))
    #expect(!afterOneSecond.contains(.memory))
    #expect(!afterOneSecond.contains(.battery))
    #expect(!afterOneSecond.contains(.codex))

    let afterSixtySeconds = policy.dueMetrics(
        lastSampled: sampled,
        now: start.addingTimeInterval(60),
        isForeground: true
    )
    #expect(afterSixtySeconds == Set(LiveMetric.allCases))
}

@Test func adaptivePolicySlowsSamplingInBackground() {
    let policy = AdaptiveSamplingPolicy.standard
    let start = Date(timeIntervalSince1970: 1_000)
    let sampled = Dictionary(uniqueKeysWithValues: LiveMetric.allCases.map { ($0, start) })

    let afterFiveSeconds = policy.dueMetrics(
        lastSampled: sampled,
        now: start.addingTimeInterval(5),
        isForeground: false
    )
    #expect(afterFiveSeconds.contains(.cpu))
    #expect(afterFiveSeconds.contains(.network))
    #expect(!afterFiveSeconds.contains(.memory))
    #expect(!afterFiveSeconds.contains(.storage))
}

@Test func liveMonitoringFansOutOneSamplingPipeline() async throws {
    let coordinator = FakeLiveCoordinator()
    let policy = AdaptiveSamplingPolicy(intervals: Dictionary(
        uniqueKeysWithValues: LiveMetric.allCases.map {
            ($0, SamplingInterval(foreground: 3_600, background: 3_600))
        }
    ))
    let service = LiveMonitoringService(coordinator: coordinator, policy: policy)
    let firstStream = await service.reports()
    let secondStream = await service.reports()
    var firstIterator = firstStream.makeAsyncIterator()
    var secondIterator = secondStream.makeAsyncIterator()

    let firstInitial = try #require(await firstIterator.next())
    let secondInitial = try #require(await secondIterator.next())
    #expect(firstInitial.system.cpuValue == secondInitial.system.cpuValue)

    await service.refreshNow()
    let firstRefresh = try #require(await firstIterator.next())
    let secondRefresh = try #require(await secondIterator.next())
    #expect(firstRefresh.system.cpuValue == secondRefresh.system.cpuValue)
    #expect(firstRefresh.system.cpuValue != firstInitial.system.cpuValue)
    #expect(await coordinator.systemSampleCount() == 2)

    await service.stop()
}

private actor FakeLiveCoordinator: LiveDiagnosticCoordinating {
    private var samples = 0

    func sampleSystem(previous: SystemSnapshot?, metrics: Set<LiveMetric>) async -> SystemSnapshot {
        samples += 1
        return SystemSnapshot(
            timestamp: Date(),
            cpu: .available(CPUReading(usagePercent: Double(samples))),
            memory: previous?.memory ?? .unavailable(reason: "Not sampled"),
            storage: previous?.storage ?? .unavailable(reason: "Not sampled"),
            network: previous?.network ?? .unavailable(reason: "Not sampled"),
            battery: previous?.battery ?? .unavailable(reason: "Not sampled"),
            thermalState: .nominal,
            advancedSensors: AdvancedSensorSnapshot(
                cpuTemperature: .unavailable(reason: "Not sampled"),
                gpuUsage: .unavailable(reason: "Not sampled"),
                fanSpeeds: .unavailable(reason: "Not sampled")
            )
        )
    }

    func runCodexDiagnostics() async -> Availability<CodexDiagnosticSnapshot> {
        .unavailable(reason: "Not sampled")
    }

    func runCursorDiagnostics() async -> Availability<CursorUsageSnapshot> {
        .unavailable(reason: "Not sampled")
    }

    func systemSampleCount() -> Int {
        samples
    }
}

private extension SystemSnapshot {
    var cpuValue: Double? {
        guard case .available(let reading) = cpu else { return nil }
        return reading.usagePercent
    }
}
