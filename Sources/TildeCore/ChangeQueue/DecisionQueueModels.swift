import Foundation

public enum DecisionSeverity: String, Sendable, Equatable {
    case pass
    case warn
    case fail
    case info
}

public enum DecisionReasonKind: String, Sendable, Equatable {
    case agentBlocked
    case agentReady
    case verificationPassed
    case verificationFailed
    case verificationStale
    case verificationMissing
    case verificationUntrusted
    case verificationRunning
    case sensitiveFiles
    case ciPending
    case ciFailed
    case ciUnknown
    case largeChange
    case branchBehind
    case working
    case idle
    case dirtyChange
}

public struct DecisionReason: Identifiable, Sendable, Equatable {
    public var id: String { "\(kind.rawValue)|\(message)" }
    public let kind: DecisionReasonKind
    public let severity: DecisionSeverity
    public let message: String

    public init(kind: DecisionReasonKind, severity: DecisionSeverity, message: String) {
        self.kind = kind
        self.severity = severity
        self.message = message
    }
}

public enum DecisionActionKind: String, Sendable, Equatable {
    case reviewChange
    case runChecks
    case openAgent
    case trustProfile
}

public struct DecisionAction: Identifiable, Sendable, Equatable {
    public var id: String { kind.rawValue }
    public let kind: DecisionActionKind
    public let title: String
    public let isEnabled: Bool

    public init(kind: DecisionActionKind, title: String, isEnabled: Bool = true) {
        self.kind = kind
        self.title = title
        self.isEnabled = isEnabled
    }
}

/// One human decision about one agent-produced change (repo + worktree), not one process.
public struct DecisionQueueItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let projectName: String
    public let branch: String?
    public let worktreePath: String
    public let reasons: [DecisionReason]
    public let actions: [DecisionAction]
    public let agentTerminalIDs: [String]
    public let priority: Int
    public let needsYou: Bool

    public init(
        id: String,
        title: String,
        subtitle: String,
        projectName: String,
        branch: String?,
        worktreePath: String,
        reasons: [DecisionReason],
        actions: [DecisionAction],
        agentTerminalIDs: [String],
        priority: Int,
        needsYou: Bool
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.projectName = projectName
        self.branch = branch
        self.worktreePath = worktreePath
        self.reasons = reasons
        self.actions = actions
        self.agentTerminalIDs = agentTerminalIDs
        self.priority = priority
        self.needsYou = needsYou
    }
}

public struct DecisionQueueSnapshot: Sendable, Equatable {
    public var items: [DecisionQueueItem]
    public var workingCount: Int
    public var idleCount: Int
    public var sampledAt: Date

    public init(
        items: [DecisionQueueItem] = [],
        workingCount: Int = 0,
        idleCount: Int = 0,
        sampledAt: Date = Date()
    ) {
        self.items = items
        self.workingCount = workingCount
        self.idleCount = idleCount
        self.sampledAt = sampledAt
    }

    public static let empty = DecisionQueueSnapshot()

    public var needsYouItems: [DecisionQueueItem] {
        Array(items.filter(\.needsYou).prefix(3))
    }

    public var topItem: DecisionQueueItem? { items.first }
}
