import Foundation

public struct ClaudeMessageTokenUsage: Equatable, Sendable {
    public let sessionID: String
    public let messageID: String
    public let model: String
    public let timestamp: Date
    public let inputTokens: Int
    public let cacheWriteFiveMinuteTokens: Int
    public let cacheWriteOneHourTokens: Int
    public let cacheReadTokens: Int
    public let outputTokens: Int

    public init(
        sessionID: String,
        messageID: String,
        model: String,
        timestamp: Date,
        inputTokens: Int,
        cacheWriteFiveMinuteTokens: Int,
        cacheWriteOneHourTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int
    ) {
        self.sessionID = sessionID
        self.messageID = messageID
        self.model = model
        self.timestamp = timestamp
        self.inputTokens = max(0, inputTokens)
        self.cacheWriteFiveMinuteTokens = max(0, cacheWriteFiveMinuteTokens)
        self.cacheWriteOneHourTokens = max(0, cacheWriteOneHourTokens)
        self.cacheReadTokens = max(0, cacheReadTokens)
        self.outputTokens = max(0, outputTokens)
    }

    public var totalTokens: Int {
        inputTokens
            + cacheWriteFiveMinuteTokens
            + cacheWriteOneHourTokens
            + cacheReadTokens
            + outputTokens
    }

    var identity: String { "\(sessionID)|\(messageID)" }

    func mergingBestRecord(with other: ClaudeMessageTokenUsage) -> ClaudeMessageTokenUsage {
        if totalTokens != other.totalTokens {
            return totalTokens > other.totalTokens ? self : other
        }
        if cacheWriteOneHourTokens != other.cacheWriteOneHourTokens {
            return cacheWriteOneHourTokens > other.cacheWriteOneHourTokens ? self : other
        }
        return timestamp >= other.timestamp ? self : other
    }
}

public struct ClaudeCostEstimate: Equatable, Sendable {
    public let cents: Int
    public let pricedMessageCount: Int
    public let totalMessageCount: Int
    public let sessionCount: Int
    public let classifiedTokens: Int
    public let models: [String]
    public let unpricedModels: [String]

    public init(
        cents: Int,
        pricedMessageCount: Int,
        totalMessageCount: Int,
        sessionCount: Int,
        classifiedTokens: Int,
        models: [String],
        unpricedModels: [String]
    ) {
        self.cents = max(0, cents)
        self.pricedMessageCount = max(0, pricedMessageCount)
        self.totalMessageCount = max(0, totalMessageCount)
        self.sessionCount = max(0, sessionCount)
        self.classifiedTokens = max(0, classifiedTokens)
        self.models = models
        self.unpricedModels = unpricedModels
    }
}

public enum ClaudeCostEstimator {
    /// Anthropic API price card reviewed 2026-07-18.
    public static let rateCardVersion = "2026-07-18"

    private struct Rate {
        let inputUSDPerMillion: Double
        let cacheWriteFiveMinuteUSDPerMillion: Double
        let cacheWriteOneHourUSDPerMillion: Double
        let cacheReadUSDPerMillion: Double
        let outputUSDPerMillion: Double
    }

    public static func estimate(messages: [ClaudeMessageTokenUsage]) -> ClaudeCostEstimate? {
        var deduplicated: [String: ClaudeMessageTokenUsage] = [:]
        for message in messages where message.totalTokens > 0 {
            deduplicated[message.identity] = deduplicated[message.identity]
                .map { $0.mergingBestRecord(with: message) } ?? message
        }
        guard !deduplicated.isEmpty else { return nil }

        var totalUSD = 0.0
        var pricedMessages = 0
        var classifiedTokens = 0
        var pricedModels = Set<String>()
        var unpricedModels = Set<String>()

        for message in deduplicated.values {
            guard let rate = rate(for: message.model, at: message.timestamp) else {
                unpricedModels.insert(message.model)
                continue
            }
            pricedMessages += 1
            classifiedTokens += message.totalTokens
            pricedModels.insert(message.model)
            totalUSD += Double(message.inputTokens) * rate.inputUSDPerMillion / 1_000_000
            totalUSD += Double(message.cacheWriteFiveMinuteTokens)
                * rate.cacheWriteFiveMinuteUSDPerMillion / 1_000_000
            totalUSD += Double(message.cacheWriteOneHourTokens)
                * rate.cacheWriteOneHourUSDPerMillion / 1_000_000
            totalUSD += Double(message.cacheReadTokens) * rate.cacheReadUSDPerMillion / 1_000_000
            totalUSD += Double(message.outputTokens) * rate.outputUSDPerMillion / 1_000_000
        }
        guard pricedMessages > 0 else { return nil }

        return ClaudeCostEstimate(
            cents: Int((totalUSD * 100).rounded()),
            pricedMessageCount: pricedMessages,
            totalMessageCount: deduplicated.count,
            sessionCount: Set(deduplicated.values.map(\.sessionID)).count,
            classifiedTokens: classifiedTokens,
            models: pricedModels.sorted(),
            unpricedModels: unpricedModels.sorted()
        )
    }

    private static func rate(for rawModel: String, at date: Date) -> Rate? {
        let model = rawModel.lowercased()
            .replacingOccurrences(of: "[1m]", with: "")

        if model.contains("fable-5") || model.contains("mythos-5") || model.contains("mythos-preview") {
            return Rate(
                inputUSDPerMillion: 10,
                cacheWriteFiveMinuteUSDPerMillion: 12.5,
                cacheWriteOneHourUSDPerMillion: 20,
                cacheReadUSDPerMillion: 1,
                outputUSDPerMillion: 50
            )
        }
        if model.contains("sonnet-5") {
            let promoEnd = ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z")!
            let input = date < promoEnd ? 2.0 : 3.0
            let output = date < promoEnd ? 10.0 : 15.0
            return Rate(
                inputUSDPerMillion: input,
                cacheWriteFiveMinuteUSDPerMillion: input * 1.25,
                cacheWriteOneHourUSDPerMillion: input * 2,
                cacheReadUSDPerMillion: input * 0.1,
                outputUSDPerMillion: output
            )
        }
        if model.contains("opus-4-8") || model.contains("opus-4-7")
            || model.contains("opus-4-6") || model.contains("opus-4-5") {
            return Rate(
                inputUSDPerMillion: 5,
                cacheWriteFiveMinuteUSDPerMillion: 6.25,
                cacheWriteOneHourUSDPerMillion: 10,
                cacheReadUSDPerMillion: 0.5,
                outputUSDPerMillion: 25
            )
        }
        if model.contains("opus-4-1") || model.contains("opus-4-20") || model.hasSuffix("opus-4") {
            return Rate(
                inputUSDPerMillion: 15,
                cacheWriteFiveMinuteUSDPerMillion: 18.75,
                cacheWriteOneHourUSDPerMillion: 30,
                cacheReadUSDPerMillion: 1.5,
                outputUSDPerMillion: 75
            )
        }
        if model.contains("sonnet-4") || model.contains("sonnet-3-7") {
            return Rate(
                inputUSDPerMillion: 3,
                cacheWriteFiveMinuteUSDPerMillion: 3.75,
                cacheWriteOneHourUSDPerMillion: 6,
                cacheReadUSDPerMillion: 0.3,
                outputUSDPerMillion: 15
            )
        }
        if model.contains("haiku-4-5") {
            return Rate(
                inputUSDPerMillion: 1,
                cacheWriteFiveMinuteUSDPerMillion: 1.25,
                cacheWriteOneHourUSDPerMillion: 2,
                cacheReadUSDPerMillion: 0.1,
                outputUSDPerMillion: 5
            )
        }
        if model.contains("haiku-3-5") {
            return Rate(
                inputUSDPerMillion: 0.8,
                cacheWriteFiveMinuteUSDPerMillion: 1,
                cacheWriteOneHourUSDPerMillion: 1.6,
                cacheReadUSDPerMillion: 0.08,
                outputUSDPerMillion: 4
            )
        }
        return nil
    }
}

struct ClaudeTranscriptUsageParser {
    private(set) var messages: [String: ClaudeMessageTokenUsage] = [:]

    private struct TranscriptEnvelope: Decodable {
        let type: String?
        let timestamp: String?
        let sessionID: String?
        let snakeSessionID: String?
        let messageID: String?
        let uuid: String?
        let message: Message?

        enum CodingKeys: String, CodingKey {
            case type
            case timestamp
            case sessionID = "sessionId"
            case snakeSessionID = "session_id"
            case messageID = "messageId"
            case uuid
            case message
        }

        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?
            let outputTokens: Int?
            let cacheCreation: CacheCreation?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreation = "cache_creation"
            }
        }

        struct CacheCreation: Decodable {
            let fiveMinuteTokens: Int?
            let oneHourTokens: Int?

            enum CodingKeys: String, CodingKey {
                case fiveMinuteTokens = "ephemeral_5m_input_tokens"
                case oneHourTokens = "ephemeral_1h_input_tokens"
            }
        }
    }

    mutating func consume(lineData: Data, interval: Range<Date>) {
        let assistantMarker = Data(#""assistant""#.utf8)
        let usageMarker = Data(#""usage""#.utf8)
        guard lineData.range(of: assistantMarker) != nil,
              lineData.range(of: usageMarker) != nil,
              let envelope = try? JSONDecoder().decode(TranscriptEnvelope.self, from: lineData),
              envelope.type == "assistant",
              let timestamp = Self.date(envelope.timestamp),
              interval.contains(timestamp),
              let message = envelope.message,
              let usage = message.usage,
              let model = message.model,
              !model.isEmpty else { return }

        let messageID = message.id ?? envelope.messageID ?? envelope.uuid
        guard let messageID, !messageID.isEmpty else { return }
        let sessionID = envelope.sessionID
            ?? envelope.snakeSessionID
            ?? "unknown-session"

        let totalCacheWrite = max(0, usage.cacheCreationInputTokens ?? 0)
        let oneHourCacheWrite = max(0, usage.cacheCreation?.oneHourTokens ?? 0)
        let explicitFiveMinuteCacheWrite = max(0, usage.cacheCreation?.fiveMinuteTokens ?? 0)
        let unspecifiedCacheWrite = max(
            0,
            totalCacheWrite - oneHourCacheWrite - explicitFiveMinuteCacheWrite
        )
        let parsed = ClaudeMessageTokenUsage(
            sessionID: sessionID,
            messageID: messageID,
            model: model,
            timestamp: timestamp,
            inputTokens: usage.inputTokens ?? 0,
            cacheWriteFiveMinuteTokens: explicitFiveMinuteCacheWrite + unspecifiedCacheWrite,
            cacheWriteOneHourTokens: oneHourCacheWrite,
            cacheReadTokens: usage.cacheReadInputTokens ?? 0,
            outputTokens: usage.outputTokens ?? 0
        )
        guard parsed.totalTokens > 0 else { return }
        messages[parsed.identity] = messages[parsed.identity]
            .map { $0.mergingBestRecord(with: parsed) } ?? parsed
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
