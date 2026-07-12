import Foundation

public enum AgentAttentionState: String, Codable, Sendable, Equatable, CaseIterable {
    case blocked
    case working
    case done
    case idle
    case unknown

    public var needsAttention: Bool {
        self == .blocked || self == .done
    }

    public var label: String {
        switch self {
        case .blocked: return "Needs input"
        case .working: return "Working"
        case .done: return "Ready to review"
        case .idle: return "Idle"
        case .unknown: return "Unknown"
        }
    }

    public var displayPriority: Int {
        switch self {
        case .blocked: return 0
        case .done: return 1
        case .working: return 2
        case .idle: return 3
        case .unknown: return 4
        }
    }
}
public struct AgentAttentionItem: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let terminalID: String
    public let paneID: String?
    public let workspaceID: String?
    public let agent: String
    public let state: AgentAttentionState
    public let cwd: String
    public let projectRoot: String?
    public let projectName: String
    public let branch: String?
    public let focused: Bool

    public init(
        id: String,
        terminalID: String,
        paneID: String?,
        workspaceID: String?,
        agent: String,
        state: AgentAttentionState,
        cwd: String,
        projectRoot: String?,
        projectName: String,
        branch: String?,
        focused: Bool
    ) {
        self.id = id
        self.terminalID = terminalID
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.agent = agent
        self.state = state
        self.cwd = cwd
        self.projectRoot = projectRoot
        self.projectName = projectName
        self.branch = branch
        self.focused = focused
    }
}

public struct AgentAttentionSnapshot: Sendable, Equatable {
    public var agents: [AgentAttentionItem]
    public var sampledAt: Date
    public var providerAvailable: Bool
    public var unavailableReason: String?

    public init(
        agents: [AgentAttentionItem] = [],
        sampledAt: Date = Date(),
        providerAvailable: Bool = false,
        unavailableReason: String? = nil
    ) {
        self.agents = agents
        self.sampledAt = sampledAt
        self.providerAvailable = providerAvailable
        self.unavailableReason = unavailableReason
    }

    public static let unavailable = AgentAttentionSnapshot(
        providerAvailable: false,
        unavailableReason: "Herdr is not connected"
    )

    public var attentionItems: [AgentAttentionItem] {
        agents
            .filter { $0.state.needsAttention }
            .sorted { lhs, rhs in
                if lhs.state != rhs.state { return lhs.state == .blocked }
                return lhs.projectName.localizedCaseInsensitiveCompare(rhs.projectName) == .orderedAscending
            }
    }

    public var attentionCount: Int { attentionItems.count }
    public var workingCount: Int { agents.filter { $0.state == .working }.count }

    /// Every currently detected agent, ordered for the menu panel. Idle agents stay
    /// available here even though they do not add noise to the menu-bar title.
    public var displayItems: [AgentAttentionItem] {
        agents.sorted { lhs, rhs in
            if lhs.state.displayPriority != rhs.state.displayPriority {
                return lhs.state.displayPriority < rhs.state.displayPriority
            }
            if lhs.focused != rhs.focused { return lhs.focused }
            let projectOrder = lhs.projectName.localizedCaseInsensitiveCompare(rhs.projectName)
            if projectOrder != .orderedSame { return projectOrder == .orderedAscending }
            return lhs.agent.localizedCaseInsensitiveCompare(rhs.agent) == .orderedAscending
        }
    }
}

public enum AgentAttentionEventKind: String, Sendable, Equatable {
    case needsInput
    case completed
}

public struct AgentAttentionEvent: Sendable, Equatable {
    public let kind: AgentAttentionEventKind
    public let agent: AgentAttentionItem

    public init(kind: AgentAttentionEventKind, agent: AgentAttentionItem) {
        self.kind = kind
        self.agent = agent
    }
}

public struct AgentAttentionRefresh: Sendable, Equatable {
    public let snapshot: AgentAttentionSnapshot
    public let events: [AgentAttentionEvent]

    public init(snapshot: AgentAttentionSnapshot, events: [AgentAttentionEvent]) {
        self.snapshot = snapshot
        self.events = events
    }
}

public actor AgentAttentionMonitor {
    public typealias FetchSnapshot = @Sendable () async -> AgentAttentionSnapshot

    private let fetchSnapshot: FetchSnapshot
    private var previousStates: [String: AgentAttentionState] = [:]
    private var hasBaseline = false

    public init(fetchSnapshot: @escaping FetchSnapshot) {
        self.fetchSnapshot = fetchSnapshot
    }

    public func refresh() async -> AgentAttentionRefresh {
        let snapshot = await fetchSnapshot()
        guard snapshot.providerAvailable else {
            return AgentAttentionRefresh(snapshot: snapshot, events: [])
        }

        var events: [AgentAttentionEvent] = []
        if hasBaseline {
            for agent in snapshot.agents {
                guard previousStates[agent.id] != agent.state else { continue }
                switch agent.state {
                case .blocked:
                    events.append(AgentAttentionEvent(kind: .needsInput, agent: agent))
                case .done:
                    events.append(AgentAttentionEvent(kind: .completed, agent: agent))
                case .working, .idle, .unknown:
                    break
                }
            }
        }

        previousStates = Dictionary(uniqueKeysWithValues: snapshot.agents.map { ($0.id, $0.state) })
        hasBaseline = true
        return AgentAttentionRefresh(snapshot: snapshot, events: events)
    }
}
