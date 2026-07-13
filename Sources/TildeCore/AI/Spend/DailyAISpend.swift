import Foundation

public enum AISpendProvider: String, Codable, CaseIterable, Sendable {
    case codex
    case cursor

    public var label: String {
        switch self {
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }
}

public enum DailySpendBasis: String, Codable, Sendable {
    /// The provider returned a monetary value scoped to the current day.
    case providerReported
    /// Tilde calculated a delta from a cumulative monetary meter it observed locally.
    case locallyObservedDelta
    /// Tilde converted a model-specific token breakdown through an official credit rate card.
    case estimatedFromTokenBreakdown
}

public struct DailySpendReading: Codable, Equatable, Sendable {
    public let provider: AISpendProvider
    public let cents: Int
    public let basis: DailySpendBasis
    public let observedFrom: Date

    public init(
        provider: AISpendProvider,
        cents: Int,
        basis: DailySpendBasis,
        observedFrom: Date
    ) {
        self.provider = provider
        self.cents = max(0, cents)
        self.basis = basis
        self.observedFrom = observedFrom
    }
}

public struct DailyAISpendSummary: Equatable, Sendable {
    public let codex: DailySpendReading?
    public let cursor: DailySpendReading?

    public init(codex: DailySpendReading?, cursor: DailySpendReading?) {
        self.codex = codex
        self.cursor = cursor
    }

    public var knownTotalCents: Int? {
        let known = [codex, cursor].compactMap { $0 }
        guard !known.isEmpty else { return nil }
        return known.reduce(0) { $0 + $1.cents }
    }

    /// True only when both providers report a value already scoped to today.
    public var hasCompleteProviderCoverage: Bool {
        codex?.basis == .providerReported && cursor?.basis == .providerReported
    }

    public var containsEstimate: Bool {
        [codex, cursor].compactMap { $0 }.contains { $0.basis == .estimatedFromTokenBreakdown }
    }

    public var menuBarText: String {
        guard let knownTotalCents else { return "$— today" }
        let estimate = containsEstimate ? "≈" : ""
        let lowerBound = hasCompleteProviderCoverage ? "" : "+"
        return "\(estimate)\(Self.usd(knownTotalCents))\(lowerBound) today"
    }

    public var detailText: String {
        [providerDetail(.cursor, reading: cursor), providerDetail(.codex, reading: codex)]
            .joined(separator: " · ")
    }

    public static func usd(_ cents: Int) -> String {
        let safe = max(0, cents)
        return String(format: "$%d.%02d", safe / 100, safe % 100)
    }

    private func providerDetail(_ provider: AISpendProvider, reading: DailySpendReading?) -> String {
        guard let reading else { return "\(provider.label) not reported" }
        switch reading.basis {
        case .providerReported:
            return "\(provider.label) \(Self.usd(reading.cents))"
        case .locallyObservedDelta:
            return "\(provider.label) \(Self.usd(reading.cents)) observed"
        case .estimatedFromTokenBreakdown:
            return "\(provider.label) ≈\(Self.usd(reading.cents))"
        }
    }
}

public struct CumulativeSpendMeterState: Codable, Equatable, Sendable {
    public let dateKey: String
    public let periodID: String
    public let baselineCents: Int
    public let latestCents: Int
    public let observedFrom: Date

    public init(
        dateKey: String,
        periodID: String,
        baselineCents: Int,
        latestCents: Int,
        observedFrom: Date
    ) {
        self.dateKey = dateKey
        self.periodID = periodID
        self.baselineCents = baselineCents
        self.latestCents = latestCents
        self.observedFrom = observedFrom
    }
}

public enum CumulativeSpendMeter {
    public static func record(
        previous: CumulativeSpendMeterState?,
        cumulativeCents: Int,
        periodID: String,
        at date: Date,
        calendar: Calendar = .current
    ) -> (state: CumulativeSpendMeterState, dailyCents: Int) {
        let cents = max(0, cumulativeCents)
        let dateKey = localDateKey(date, calendar: calendar)
        guard let previous,
              previous.dateKey == dateKey,
              previous.periodID == periodID,
              cents >= previous.latestCents else {
            return (
                CumulativeSpendMeterState(
                    dateKey: dateKey,
                    periodID: periodID,
                    baselineCents: cents,
                    latestCents: cents,
                    observedFrom: date
                ),
                0
            )
        }

        let state = CumulativeSpendMeterState(
            dateKey: previous.dateKey,
            periodID: previous.periodID,
            baselineCents: previous.baselineCents,
            latestCents: cents,
            observedFrom: previous.observedFrom
        )
        return (state, max(0, cents - previous.baselineCents))
    }

    private static func localDateKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

public actor DailySpendLedger {
    public static let shared = DailySpendLedger(fileURL: defaultFileURL())

    private let fileURL: URL
    private var states: [AISpendProvider: CumulativeSpendMeterState]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func record(
        provider: AISpendProvider,
        cumulativeCents: Int,
        periodID: String,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) throws -> DailySpendReading {
        var loaded = try loadIfNeeded()
        let update = CumulativeSpendMeter.record(
            previous: loaded[provider],
            cumulativeCents: cumulativeCents,
            periodID: periodID,
            at: date,
            calendar: calendar
        )
        loaded[provider] = update.state
        try persist(loaded)
        states = loaded
        return DailySpendReading(
            provider: provider,
            cents: update.dailyCents,
            basis: .locallyObservedDelta,
            observedFrom: update.state.observedFrom
        )
    }

    private func loadIfNeeded() throws -> [AISpendProvider: CumulativeSpendMeterState] {
        if let states { return states }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            states = [:]
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        let decoded: [AISpendProvider: CumulativeSpendMeterState]
        if let keyed = try? decoder.decode([String: CumulativeSpendMeterState].self, from: data) {
            decoded = Dictionary(uniqueKeysWithValues: keyed.compactMap { key, value in
                AISpendProvider(rawValue: key).map { ($0, value) }
            })
        } else {
            // Migrate the short-lived array encoding used by the first local prototype.
            decoded = try decoder.decode([AISpendProvider: CumulativeSpendMeterState].self, from: data)
        }
        states = decoded
        return decoded
    }

    private func persist(_ states: [AISpendProvider: CumulativeSpendMeterState]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let keyed = Dictionary(uniqueKeysWithValues: states.map { ($0.key.rawValue, $0.value) })
        try encoder.encode(keyed).write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tilde", isDirectory: true)
            .appendingPathComponent("daily-ai-spend.json")
    }
}

public enum ExplicitMonetaryValueParser {
    private static let centKeys = ["spendCents", "costCents", "totalCostCents", "chargedCents"]

    public static func cents(in dictionary: [String: Any]?) -> Int? {
        guard let dictionary else { return nil }
        for key in centKeys {
            guard let value = dictionary[key] else { continue }
            if let number = value as? NSNumber {
                return max(0, Int(number.doubleValue.rounded()))
            }
            if let string = value as? String, let number = Double(string) {
                return max(0, Int(number.rounded()))
            }
        }
        return nil
    }
}
