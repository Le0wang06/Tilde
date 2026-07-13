import Foundation

public struct CursorUsageSnapshot: Sendable, Equatable {
    public let remainingPercent: Int?
    public let usedPercent: Double?
    public let planName: String?
    public let billingCycleEnd: Date?
    public let displayMessage: String?
    public let dailySpend: DailySpendReading?
    public let notes: [String]

    public init(
        remainingPercent: Int?,
        usedPercent: Double?,
        planName: String?,
        billingCycleEnd: Date?,
        displayMessage: String?,
        dailySpend: DailySpendReading? = nil,
        notes: [String] = []
    ) {
        self.remainingPercent = remainingPercent
        self.usedPercent = usedPercent
        self.planName = planName
        self.billingCycleEnd = billingCycleEnd
        self.displayMessage = displayMessage
        self.dailySpend = dailySpend
        self.notes = notes
    }
}
