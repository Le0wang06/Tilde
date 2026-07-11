import Foundation

public struct CodexRateLimitWindow: Sendable, Equatable {
    public let usedPercent: Int
    public let resetsAt: Date?
    public let durationMinutes: Int?

    public var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }

    public init(usedPercent: Int, resetsAt: Date?, durationMinutes: Int?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.durationMinutes = durationMinutes
    }
}

public struct CodexDiagnosticSnapshot: Sendable {
    public let executablePath: String
    public let version: String
    public let isAuthenticated: Bool
    public let accountType: String?
    public let planType: String?
    public let primaryLimit: CodexRateLimitWindow?
    public let secondaryLimit: CodexRateLimitWindow?
    public let tokensToday: Int?
    public let lifetimeTokens: Int?
    public let threadCount: Int?
    public let notes: [String]

    public init(
        executablePath: String,
        version: String,
        isAuthenticated: Bool,
        accountType: String?,
        planType: String?,
        primaryLimit: CodexRateLimitWindow?,
        secondaryLimit: CodexRateLimitWindow?,
        tokensToday: Int?,
        lifetimeTokens: Int?,
        threadCount: Int?,
        notes: [String]
    ) {
        self.executablePath = executablePath
        self.version = version
        self.isAuthenticated = isAuthenticated
        self.accountType = accountType
        self.planType = planType
        self.primaryLimit = primaryLimit
        self.secondaryLimit = secondaryLimit
        self.tokensToday = tokensToday
        self.lifetimeTokens = lifetimeTokens
        self.threadCount = threadCount
        self.notes = notes
    }
}

public struct DiagnosticReport: Sendable {
    public let system: SystemSnapshot
    public let codex: Availability<CodexDiagnosticSnapshot>

    public init(system: SystemSnapshot, codex: Availability<CodexDiagnosticSnapshot>) {
        self.system = system
        self.codex = codex
    }
}
