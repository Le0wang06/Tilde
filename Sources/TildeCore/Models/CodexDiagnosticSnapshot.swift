import Foundation

public enum CodexRateLimitKind: String, Sendable, Equatable, CaseIterable {
    case fiveHour
    case weekly
    case other

    public var label: String {
        switch self {
        case .fiveHour: return "5-hour window"
        case .weekly: return "7-day window"
        case .other: return "Usage window"
        }
    }

    public var compactLabel: String {
        switch self {
        case .fiveHour: return "5h"
        case .weekly: return "7d"
        case .other: return "Usage"
        }
    }
}

public struct CodexRateLimitWindow: Sendable, Equatable {
    public let usedPercent: Int
    public let resetsAt: Date?
    public let durationMinutes: Int?

    public var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }

    /// The app-server protocol names windows `primary` and `secondary`, but
    /// their positions are not semantic. Classify only from the reported duration.
    public var kind: CodexRateLimitKind {
        switch durationMinutes {
        case 300: return .fiveHour
        case 10_080: return .weekly
        default: return .other
        }
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
    public let dailySpend: DailySpendReading?
    public let estimatedCreditsToday: Double?
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
        dailySpend: DailySpendReading? = nil,
        estimatedCreditsToday: Double? = nil,
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
        self.dailySpend = dailySpend
        self.estimatedCreditsToday = estimatedCreditsToday
        self.lifetimeTokens = lifetimeTokens
        self.threadCount = threadCount
        self.notes = notes
    }

    public var rateLimitWindows: [CodexRateLimitWindow] {
        [primaryLimit, secondaryLimit].compactMap { $0 }
    }

    public var fiveHourLimit: CodexRateLimitWindow? {
        rateLimitWindows.first { $0.kind == .fiveHour }
    }

    public var weeklyLimit: CodexRateLimitWindow? {
        rateLimitWindows.first { $0.kind == .weekly }
    }

    /// Prefer the short rolling window in the menu bar, while retaining a
    /// truthful label when only the weekly or an unknown window is reported.
    public var menuBarLimit: CodexRateLimitWindow? {
        fiveHourLimit ?? weeklyLimit ?? rateLimitWindows.first
    }
}

public struct DiagnosticReport: Sendable {
    public let system: SystemSnapshot
    public let codex: Availability<CodexDiagnosticSnapshot>
    public let cursor: Availability<CursorUsageSnapshot>
    public let claude: Availability<ClaudeUsageSnapshot>

    public init(
        system: SystemSnapshot,
        codex: Availability<CodexDiagnosticSnapshot>,
        cursor: Availability<CursorUsageSnapshot> = .unavailable(reason: "Waiting for first Cursor sample"),
        claude: Availability<ClaudeUsageSnapshot> = .unavailable(reason: "Waiting for first Claude sample")
    ) {
        self.system = system
        self.codex = codex
        self.cursor = cursor
        self.claude = claude
    }
}
