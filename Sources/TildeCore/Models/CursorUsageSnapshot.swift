import Foundation

public struct CursorUsageSnapshot: Sendable, Equatable {
    public let remainingPercent: Int?
    public let usedPercent: Double?
    public let planName: String?
    public let billingCycleEnd: Date?
    public let displayMessage: String?
    public let notes: [String]

    public init(
        remainingPercent: Int?,
        usedPercent: Double?,
        planName: String?,
        billingCycleEnd: Date?,
        displayMessage: String?,
        notes: [String] = []
    ) {
        self.remainingPercent = remainingPercent
        self.usedPercent = usedPercent
        self.planName = planName
        self.billingCycleEnd = billingCycleEnd
        self.displayMessage = displayMessage
        self.notes = notes
    }
}
