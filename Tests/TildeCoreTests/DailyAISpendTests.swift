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
    #expect(complete.menuBarText == "$4.38")
    #expect(partial.knownTotalCents == 155)
    #expect(partial.menuBarText == "$1.55")
    #expect(partial.detailText == "Cursor $1.55 observed · Codex not reported · Claude not reported")
    #expect(unavailable.knownTotalCents == nil)
    #expect(unavailable.menuBarText == "$—")
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
    #expect(summary.menuBarText == "≈$55.38")
    #expect(summary.detailText == "Cursor $0.00 observed · Codex ≈$55.38 · Claude not reported")
}

@Test func dailySpendSummaryIncludesClaudeAsAnEstimatedEquivalent() {
    let start = Date(timeIntervalSince1970: 1_784_352_000)
    let summary = DailyAISpendSummary(
        codex: DailySpendReading(provider: .codex, cents: 126, basis: .providerReported, observedFrom: start),
        cursor: DailySpendReading(provider: .cursor, cents: 312, basis: .providerReported, observedFrom: start),
        claude: DailySpendReading(
            provider: .claude,
            cents: 94,
            basis: .estimatedFromTokenBreakdown,
            observedFrom: start
        )
    )

    #expect(summary.knownTotalCents == 532)
    #expect(summary.menuBarText == "≈$5.32")
    #expect(summary.containsEstimate)
    #expect(summary.detailText == "Cursor $3.12 · Codex $1.26 · Claude ≈$0.94")
}

@Test func claudeCostEstimatorPricesCacheClassesAndDeduplicatesMessages() throws {
    let timestamp = try #require(ISO8601DateFormatter().date(from: "2026-07-18T12:00:00Z"))
    let priced = ClaudeMessageTokenUsage(
        sessionID: "session-a",
        messageID: "message-a",
        model: "claude-fable-5[1m]",
        timestamp: timestamp,
        inputTokens: 1_000_000,
        cacheWriteFiveMinuteTokens: 1_000_000,
        cacheWriteOneHourTokens: 1_000_000,
        cacheReadTokens: 1_000_000,
        outputTokens: 1_000_000
    )
    let duplicate = ClaudeMessageTokenUsage(
        sessionID: "session-a",
        messageID: "message-a",
        model: "claude-fable-5[1m]",
        timestamp: timestamp,
        inputTokens: 100,
        cacheWriteFiveMinuteTokens: 100,
        cacheWriteOneHourTokens: 100,
        cacheReadTokens: 100,
        outputTokens: 100
    )
    let unknown = ClaudeMessageTokenUsage(
        sessionID: "session-b",
        messageID: "message-b",
        model: "claude-future-unknown",
        timestamp: timestamp,
        inputTokens: 1_000,
        cacheWriteFiveMinuteTokens: 0,
        cacheWriteOneHourTokens: 0,
        cacheReadTokens: 0,
        outputTokens: 0
    )

    let estimate = try #require(ClaudeCostEstimator.estimate(messages: [priced, duplicate, unknown]))

    #expect(estimate.cents == 9_350)
    #expect(estimate.pricedMessageCount == 1)
    #expect(estimate.totalMessageCount == 2)
    #expect(estimate.sessionCount == 2)
    #expect(estimate.unpricedModels == ["claude-future-unknown"])
}

@Test func claudeTranscriptParserReadsOnlyTodayUsageMetadata() throws {
    let formatter = ISO8601DateFormatter()
    let start = try #require(formatter.date(from: "2026-07-18T00:00:00Z"))
    let end = try #require(formatter.date(from: "2026-07-19T00:00:00Z"))
    let current = #"{"type":"assistant","timestamp":"2026-07-18T12:00:00Z","sessionId":"session-a","message":{"id":"message-a","model":"claude-sonnet-5","content":[{"type":"text","text":"private prompt"}],"usage":{"input_tokens":1000,"cache_creation_input_tokens":500,"cache_read_input_tokens":250,"output_tokens":100,"cache_creation":{"ephemeral_5m_input_tokens":300,"ephemeral_1h_input_tokens":200}}}}"#
    let duplicate = #"{"type":"assistant","timestamp":"2026-07-18T12:00:01Z","sessionId":"session-a","message":{"id":"message-a","model":"claude-sonnet-5","usage":{"input_tokens":1000,"cache_creation_input_tokens":500,"cache_read_input_tokens":250,"output_tokens":100}}}"#
    let outside = #"{"type":"assistant","timestamp":"2026-07-19T00:00:01Z","sessionId":"session-b","message":{"id":"message-b","model":"claude-fable-5","usage":{"input_tokens":9999,"output_tokens":9999}}}"#
    let user = #"{"type":"user","timestamp":"2026-07-18T12:00:02Z","message":{"content":"assistant usage input_tokens 9999"}}"#
    var parser = ClaudeTranscriptUsageParser()

    for line in [current, duplicate, outside, user] {
        parser.consume(lineData: Data(line.utf8), interval: start..<end)
    }
    let usage = try #require(parser.messages["session-a|message-a"])

    #expect(parser.messages.count == 1)
    #expect(usage.inputTokens == 1_000)
    #expect(usage.cacheWriteFiveMinuteTokens == 300)
    #expect(usage.cacheWriteOneHourTokens == 200)
    #expect(usage.cacheReadTokens == 250)
    #expect(usage.outputTokens == 100)
}

@Test func claudeUsageProbeIncrementallyAddsNewLocalAssistantUsage() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tilde-claude-usage-\(UUID().uuidString)", isDirectory: true)
    let projects = root.appendingPathComponent("projects", isDirectory: true)
    let transcript = projects.appendingPathComponent("session.jsonl")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

    let now = Date()
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let firstTimestamp = formatter.string(from: now.addingTimeInterval(-60))
    let secondTimestamp = formatter.string(from: now.addingTimeInterval(-30))
    let first = #"{"type":"assistant","timestamp":"\#(firstTimestamp)","sessionId":"session-a","message":{"id":"message-a","model":"claude-fable-5","usage":{"input_tokens":100000,"output_tokens":0}}}"#
    let second = #"{"type":"assistant","timestamp":"\#(secondTimestamp)","sessionId":"session-a","message":{"id":"message-b","model":"claude-fable-5","usage":{"input_tokens":0,"output_tokens":20000}}}"#
    try Data("\(first)\n".utf8).write(to: transcript)
    let probe = ClaudeUsageProbe(environment: ["CLAUDE_CONFIG_DIR": root.path])

    let initial = try await probe.fetchSnapshot(now: now)
    let handle = try FileHandle(forWritingTo: transcript)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("\(second)\n".utf8))
    try handle.close()
    let updated = try await probe.fetchSnapshot(now: now)

    #expect(initial.dailySpend?.cents == 100)
    #expect(initial.pricedMessageCount == 1)
    #expect(updated.dailySpend?.cents == 200)
    #expect(updated.pricedMessageCount == 2)
    #expect(updated.sessionCount == 1)
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
