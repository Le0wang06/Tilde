import Foundation
import Testing
@testable import TildeCore

@Test func cumulativeSpendMeterTracksSameDayDelta() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let start = Date(timeIntervalSince1970: 1_787_875_200)

    let first = CumulativeSpendMeter.record(
        previous: nil,
        cumulativeCents: 4_532,
        periodID: "cycle-a",
        at: start,
        calendar: calendar
    )
    let next = CumulativeSpendMeter.record(
        previous: first.state,
        cumulativeCents: 4_687,
        periodID: "cycle-a",
        at: start.addingTimeInterval(600),
        calendar: calendar
    )

    #expect(first.dailyCents == 0)
    #expect(next.dailyCents == 155)
    #expect(next.state.baselineCents == 4_532)
    #expect(next.state.observedFrom == start)
}

@Test func cumulativeSpendMeterResetsAcrossDayCycleAndCounterRollback() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let start = Date(timeIntervalSince1970: 1_787_875_200)
    let first = CumulativeSpendMeter.record(
        previous: nil,
        cumulativeCents: 500,
        periodID: "cycle-a",
        at: start,
        calendar: calendar
    )

    let nextDay = CumulativeSpendMeter.record(
        previous: first.state,
        cumulativeCents: 800,
        periodID: "cycle-a",
        at: start.addingTimeInterval(86_400),
        calendar: calendar
    )
    let nextCycle = CumulativeSpendMeter.record(
        previous: first.state,
        cumulativeCents: 10,
        periodID: "cycle-b",
        at: start.addingTimeInterval(60),
        calendar: calendar
    )
    let rollback = CumulativeSpendMeter.record(
        previous: first.state,
        cumulativeCents: 400,
        periodID: "cycle-a",
        at: start.addingTimeInterval(60),
        calendar: calendar
    )

    #expect(nextDay.dailyCents == 0)
    #expect(nextDay.state.baselineCents == 800)
    #expect(nextCycle.dailyCents == 0)
    #expect(nextCycle.state.periodID == "cycle-b")
    #expect(rollback.dailyCents == 0)
    #expect(rollback.state.baselineCents == 400)
}

@Test func dailySpendSummaryTotalsOnlyExplicitMoney() {
    let start = Date(timeIntervalSince1970: 1_787_875_200)
    let complete = DailyAISpendSummary(
        codex: DailySpendReading(provider: .codex, cents: 126, basis: .providerReported, observedFrom: start),
        cursor: DailySpendReading(provider: .cursor, cents: 312, basis: .providerReported, observedFrom: start)
    )
    let partial = DailyAISpendSummary(
        codex: nil,
        cursor: DailySpendReading(provider: .cursor, cents: 155, basis: .locallyObservedDelta, observedFrom: start)
    )
    let unavailable = DailyAISpendSummary(codex: nil, cursor: nil)

    #expect(complete.knownTotalCents == 438)
    #expect(complete.menuBarText == "$4.38 today")
    #expect(partial.knownTotalCents == 155)
    #expect(partial.menuBarText == "$1.55+ today")
    #expect(partial.detailText == "Cursor $1.55 observed · Codex not reported")
    #expect(unavailable.knownTotalCents == nil)
    #expect(unavailable.menuBarText == "$— today")
}

@Test func dailySpendSummaryLabelsCodexCostEquivalentAsEstimated() {
    let start = Date(timeIntervalSince1970: 1_787_875_200)
    let summary = DailyAISpendSummary(
        codex: DailySpendReading(
            provider: .codex,
            cents: 5_538,
            basis: .estimatedFromTokenBreakdown,
            observedFrom: start
        ),
        cursor: DailySpendReading(
            provider: .cursor,
            cents: 0,
            basis: .locallyObservedDelta,
            observedFrom: start
        )
    )

    #expect(summary.containsEstimate)
    #expect(summary.menuBarText == "≈$55.38+ today")
    #expect(summary.detailText == "Cursor $0.00 observed · Codex ≈$55.38")
}

@Test func codexCostEstimatorUsesRawModelSpecificTokenClassesWithoutScaling() throws {
    let estimate = try #require(CodexCostEstimator.estimate(
        reportedTokens: 9_500_000,
        breakdown: [
            CodexModelTokenUsage(
                model: "gpt-5.6-sol",
                inputTokens: 1_000_000,
                cachedInputTokens: 800_000,
                outputTokens: 100_000
            ),
        ]
    ))

    #expect(estimate.credits == 110)
    #expect(estimate.cents == 440)
    #expect(estimate.reportedTokens == 9_500_000)
    #expect(estimate.locallyClassifiedTokens == 1_100_000)
    #expect(CodexCostEstimator.estimate(
        reportedTokens: 1_000,
        breakdown: [CodexModelTokenUsage(model: "unknown", inputTokens: 1_000, cachedInputTokens: 0, outputTokens: 0)]
    ) == nil)
}

@Test func codexRolloutParserReadsOnlyDatedModelAndTokenEvents() throws {
    let formatter = ISO8601DateFormatter()
    let start = try #require(formatter.date(from: "2026-08-30T00:00:00Z"))
    let end = try #require(formatter.date(from: "2026-08-31T00:00:00Z"))
    let interval = start..<end
    let turn = #"{"timestamp":"2026-08-30T00:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#
    let token = #"{"timestamp":"2026-08-30T00:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":50}}}}"#
    let outside = #"{"timestamp":"2026-08-31T00:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":9999,"cached_input_tokens":0,"output_tokens":0}}}}"#
    let prompt = #"{"timestamp":"2026-08-30T00:00:03.000Z","type":"event_msg","payload":{"type":"user_message","message":"token_count gpt-5.6-sol"}}"#
    var parser = CodexRolloutUsageParser()

    for line in [turn, token, outside, prompt] {
        parser.consume(lineData: Data(line.utf8), interval: interval)
    }
    let usage = try #require(parser.usageByModel["gpt-5.6-sol"])

    #expect(usage.inputTokens == 1_000)
    #expect(usage.cachedInputTokens == 800)
    #expect(usage.outputTokens == 50)
}

@Test func codexLocalUsageProbeReadsOnlyNewlyAppendedEvents() throws {
    let codexHome = FileManager.default.temporaryDirectory
        .appendingPathComponent("tilde-codex-home-\(UUID().uuidString)", isDirectory: true)
    let sessions = codexHome.appendingPathComponent("sessions/2026/07/13", isDirectory: true)
    let rollout = sessions.appendingPathComponent("rollout.jsonl")
    defer { try? FileManager.default.removeItem(at: codexHome) }
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date()
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let timestamp = formatter.string(from: now)
    let turn = #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#
    let firstToken = #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":50}}}}"#
    try Data("\(turn)\n\(firstToken)\n".utf8).write(to: rollout)

    let probe = CodexLocalUsageProbe()
    let first = try #require(probe.todayBreakdown(
        environment: ["CODEX_HOME": codexHome.path],
        now: now,
        calendar: calendar
    ).first)
    let secondToken = #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":100,"output_tokens":10}}}}"#
    let handle = try FileHandle(forWritingTo: rollout)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("\(secondToken)\n".utf8))
    try handle.close()
    let second = try #require(probe.todayBreakdown(
        environment: ["CODEX_HOME": codexHome.path],
        now: now,
        calendar: calendar
    ).first)

    #expect(first.inputTokens == 1_000)
    #expect(first.outputTokens == 50)
    #expect(second.inputTokens == 1_200)
    #expect(second.cachedInputTokens == 900)
    #expect(second.outputTokens == 60)
}

@Test func explicitMonetaryParserNeverPricesTokensOrPercentages() {
    #expect(ExplicitMonetaryValueParser.cents(in: ["costCents": 123.6]) == 124)
    #expect(ExplicitMonetaryValueParser.cents(in: ["chargedCents": "42"]) == 42)
    #expect(ExplicitMonetaryValueParser.cents(in: ["tokens": 2_000_000]) == nil)
    #expect(ExplicitMonetaryValueParser.cents(in: ["usedPercent": 90]) == nil)
}

@Test func dailySpendLedgerPersistsOnlyTheCumulativeMeterState() async throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("tilde-daily-spend-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let start = Date(timeIntervalSince1970: 1_787_875_200)

    let firstLedger = DailySpendLedger(fileURL: fileURL)
    let first = try await firstLedger.record(
        provider: .cursor,
        cumulativeCents: 1_000,
        periodID: "cycle-a",
        at: start,
        calendar: calendar
    )
    let restoredLedger = DailySpendLedger(fileURL: fileURL)
    let restored = try await restoredLedger.record(
        provider: .cursor,
        cumulativeCents: 1_055,
        periodID: "cycle-a",
        at: start.addingTimeInterval(60),
        calendar: calendar
    )
    let stored = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)

    #expect(first.cents == 0)
    #expect(restored.cents == 55)
    #expect(stored.contains("\"cursor\""))
    #expect(!stored.localizedCaseInsensitiveContains("token"))
    #expect(!stored.localizedCaseInsensitiveContains("email"))
}
