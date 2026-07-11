import Testing
@testable import TildeCore

@Test func cpuUsageUsesTickDeltas() {
    let previous = CPUTickSnapshot(user: 100, system: 50, idle: 800, nice: 50)
    let current = CPUTickSnapshot(user: 140, system: 70, idle: 830, nice: 60)

    let usage = CPUUsageCalculator.usagePercent(from: previous, to: current)

    #expect(usage == 70)
}

@Test func cpuUsageRejectsCountersThatMoveBackward() {
    let previous = CPUTickSnapshot(user: 100, system: 50, idle: 800, nice: 50)
    let current = CPUTickSnapshot(user: 90, system: 40, idle: 700, nice: 40)

    #expect(CPUUsageCalculator.usagePercent(from: previous, to: current) == nil)
}

@Test func networkRatesUseByteDeltasAndElapsedTime() throws {
    let previous = NetworkCounters(receivedBytes: 1_000, sentBytes: 2_000)
    let current = NetworkCounters(receivedBytes: 5_000, sentBytes: 3_000)

    let rates = try #require(NetworkRateCalculator.rates(previous: previous, current: current, elapsed: 2))

    #expect(rates.download == 2_000)
    #expect(rates.upload == 500)
}

@Test func networkRatesRejectCounterReset() {
    let previous = NetworkCounters(receivedBytes: 5_000, sentBytes: 3_000)
    let current = NetworkCounters(receivedBytes: 100, sentBytes: 100)

    #expect(NetworkRateCalculator.rates(previous: previous, current: current, elapsed: 1) == nil)
}

@Test func memoryPressureLevelIsParsedWithoutInventingAValue() {
    #expect(MemoryPressureParser.parseLevel(1) == .normal)
    #expect(MemoryPressureParser.parseLevel(2) == .warning)
    #expect(MemoryPressureParser.parseLevel(4) == .critical)
    #expect(MemoryPressureParser.parseLevel(99) == .unavailable)
}

@Test func rateLimitRemainingIsClamped() {
    #expect(CodexRateLimitWindow(usedPercent: 37, resetsAt: nil, durationMinutes: nil).remainingPercent == 63)
    #expect(CodexRateLimitWindow(usedPercent: 120, resetsAt: nil, durationMinutes: nil).remainingPercent == 0)
    #expect(CodexRateLimitWindow(usedPercent: -10, resetsAt: nil, durationMinutes: nil).remainingPercent == 100)
}

@Test func codexLocatorIncludesUserLocalPathWithoutShellPath() {
    let candidates = CodexExecutableLocator.candidatePaths(environment: [
        "HOME": "/Users/example",
        "PATH": "/usr/bin:/bin",
    ])

    #expect(candidates.contains("/Users/example/.local/bin/codex"))
    #expect(candidates.contains("/opt/homebrew/bin/codex"))
}
