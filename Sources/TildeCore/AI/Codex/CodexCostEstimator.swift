import Foundation

public struct CodexModelTokenUsage: Equatable, Sendable {
    public let model: String
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int

    public var totalTokens: Int {
        max(0, inputTokens) + max(0, outputTokens)
    }

    public init(model: String, inputTokens: Int, cachedInputTokens: Int, outputTokens: Int) {
        self.model = model
        self.inputTokens = max(0, inputTokens)
        self.cachedInputTokens = max(0, min(inputTokens, cachedInputTokens))
        self.outputTokens = max(0, outputTokens)
    }

    func adding(_ other: CodexModelTokenUsage) -> CodexModelTokenUsage {
        CodexModelTokenUsage(
            model: model,
            inputTokens: inputTokens + other.inputTokens,
            cachedInputTokens: cachedInputTokens + other.cachedInputTokens,
            outputTokens: outputTokens + other.outputTokens
        )
    }
}

public struct CodexCostEstimate: Equatable, Sendable {
    public let cents: Int
    public let credits: Double
    public let reportedTokens: Int
    public let locallyClassifiedTokens: Int
    public let models: [String]

    public init(
        cents: Int,
        credits: Double,
        reportedTokens: Int,
        locallyClassifiedTokens: Int,
        models: [String]
    ) {
        self.cents = max(0, cents)
        self.credits = max(0, credits)
        self.reportedTokens = max(0, reportedTokens)
        self.locallyClassifiedTokens = max(0, locallyClassifiedTokens)
        self.models = models
    }
}

public enum CodexCostEstimator {
    /// Official Codex credit rate card fetched 2026-07-13.
    public static let rateCardVersion = "2026-07-13"
    public static let centsPerCredit = 4.0

    private struct Rate {
        let inputCredits: Double
        let cachedInputCredits: Double
        let outputCredits: Double
    }

    private static let rates: [String: Rate] = [
        "gpt-5.6-sol": Rate(inputCredits: 125, cachedInputCredits: 12.5, outputCredits: 750),
        "gpt-5.6-terra": Rate(inputCredits: 62.5, cachedInputCredits: 6.25, outputCredits: 375),
        "gpt-5.6-luna": Rate(inputCredits: 25, cachedInputCredits: 2.5, outputCredits: 150),
        "gpt-5.5": Rate(inputCredits: 125, cachedInputCredits: 12.5, outputCredits: 750),
        "gpt-5.4": Rate(inputCredits: 62.5, cachedInputCredits: 6.25, outputCredits: 375),
        "gpt-5.4-mini": Rate(inputCredits: 18.75, cachedInputCredits: 1.875, outputCredits: 113),
    ]

    public static func estimate(
        reportedTokens: Int?,
        breakdown: [CodexModelTokenUsage]
    ) -> CodexCostEstimate? {
        let supported = breakdown.compactMap { usage -> (CodexModelTokenUsage, Rate)? in
            guard let rate = rates[usage.model.lowercased()] else { return nil }
            return (usage, rate)
        }
        let classifiedTokens = supported.reduce(0) { $0 + $1.0.totalTokens }
        guard classifiedTokens > 0 else { return nil }

        let classifiedCredits = supported.reduce(0.0) { partial, item in
            let (usage, rate) = item
            let uncached = max(0, usage.inputTokens - usage.cachedInputTokens)
            return partial
                + Double(uncached) * rate.inputCredits / 1_000_000
                + Double(usage.cachedInputTokens) * rate.cachedInputCredits / 1_000_000
                + Double(usage.outputTokens) * rate.outputCredits / 1_000_000
        }
        // account/usage/read reports a provider-normalized activity bucket, not a raw
        // input + output total. Keep it as corroborating context; price the local raw
        // input/cache/output counters directly to avoid double-weighting or scaling.
        let total = max(0, reportedTokens ?? classifiedTokens)
        let credits = classifiedCredits
        let cents = Int((credits * centsPerCredit).rounded())
        return CodexCostEstimate(
            cents: cents,
            credits: credits,
            reportedTokens: total,
            locallyClassifiedTokens: classifiedTokens,
            models: supported.map(\.0.model).sorted()
        )
    }
}

struct CodexRolloutUsageParser {
    private(set) var currentModel: String?
    private(set) var usageByModel: [String: CodexModelTokenUsage] = [:]

    mutating func consume(lineData: Data, interval: Range<Date>) {
        let turnMarker = Data(#""type":"turn_context""#.utf8)
        let tokenMarker = Data(#""type":"token_count""#.utf8)
        guard lineData.range(of: turnMarker) != nil || lineData.range(of: tokenMarker) != nil,
              let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return }

        if object["type"] as? String == "turn_context" {
            currentModel = payload["model"] as? String
            return
        }

        guard payload["type"] as? String == "token_count",
              let model = currentModel,
              let timestamp = Self.date(object["timestamp"] as? String),
              interval.contains(timestamp),
              let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any] else { return }
        let usage = CodexModelTokenUsage(
            model: model,
            inputTokens: Self.integer(last["input_tokens"]),
            cachedInputTokens: Self.integer(last["cached_input_tokens"]),
            outputTokens: Self.integer(last["output_tokens"])
        )
        guard usage.totalTokens > 0 else { return }
        usageByModel[model] = usageByModel[model].map { $0.adding(usage) } ?? usage
    }

    private static func integer(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

final class CodexLocalUsageProbe: @unchecked Sendable {
    private struct FileState {
        var parser = CodexRolloutUsageParser()
        var offset: UInt64 = 0
        var pending = Data()
    }

    private let lock = NSLock()
    private var cachedDayStart: Date?
    private var fileStates: [String: FileState] = [:]

    func todayBreakdown(
        environment: [String: String],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [CodexModelTokenUsage] {
        lock.lock()
        defer { lock.unlock() }
        let home = environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        let start = calendar.startOfDay(for: now)
        if cachedDayStart != start {
            cachedDayStart = start
            fileStates.removeAll(keepingCapacity: true)
        }
        guard let end = calendar.date(byAdding: .day, value: 1, to: start),
              let enumerator = FileManager.default.enumerator(
                at: sessions,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }

        var seenPaths = Set<String>()
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]
            ),
                  values.isRegularFile == true,
                  (values.contentModificationDate ?? .distantPast) >= start else { continue }
            let path = fileURL.path
            seenPaths.insert(path)
            var state = fileStates[path] ?? FileState()
            if UInt64(values.fileSize ?? 0) < state.offset {
                state = FileState()
            }
            readNewLines(at: fileURL, state: &state, interval: start..<end)
            fileStates[path] = state
        }
        fileStates = fileStates.filter { seenPaths.contains($0.key) }

        var combined: [String: CodexModelTokenUsage] = [:]
        for state in fileStates.values {
            for usage in state.parser.usageByModel.values {
                combined[usage.model] = combined[usage.model].map { $0.adding(usage) } ?? usage
            }
        }
        return combined.values.sorted { $0.model < $1.model }
    }

    private func readNewLines(
        at url: URL,
        state: inout FileState,
        interval: Range<Date>
    ) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: state.offset)
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            state.pending.append(chunk)
            while let newline = state.pending.firstIndex(of: 0x0A) {
                state.parser.consume(lineData: state.pending[..<newline], interval: interval)
                state.pending.removeSubrange(...newline)
            }
        }
        state.offset = handle.offsetInFile
    }
}
