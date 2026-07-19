import Foundation

public struct ClaudeUsageSnapshot: Sendable, Equatable {
    public let dailySpend: DailySpendReading?
    public let sessionCount: Int
    public let pricedMessageCount: Int
    public let unpricedModels: [String]
    public let notes: [String]

    public init(
        dailySpend: DailySpendReading?,
        sessionCount: Int,
        pricedMessageCount: Int,
        unpricedModels: [String] = [],
        notes: [String] = []
    ) {
        self.dailySpend = dailySpend
        self.sessionCount = max(0, sessionCount)
        self.pricedMessageCount = max(0, pricedMessageCount)
        self.unpricedModels = unpricedModels
        self.notes = notes
    }
}
