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
