import Foundation

/// Shared copy for UserNotifications banners (side-of-screen alerts).
public enum AttentionBannerCopy {
    public static func title(for kind: AgentAttentionEventKind, state: AgentAttentionState = .done) -> String {
        switch kind {
        case .needsInput:
            return "Agent needs you"
        case .completed:
            // Herdr uses `done` for review-ready work and `idle` for finished turns.
            return state == .done ? "Ready to review" : "Agent finished"
        }
    }

    public static func body(for agent: AgentAttentionItem) -> String {
        let branch = agent.branch.map { " · \($0)" } ?? ""
        return "\(agent.projectName)\(branch) · \(agent.agent.capitalized)"
    }

    public static func requestID(for event: AgentAttentionEvent) -> String {
        "tilde-agent-\(event.kind.rawValue)-\(event.agent.terminalID)"
    }
}
