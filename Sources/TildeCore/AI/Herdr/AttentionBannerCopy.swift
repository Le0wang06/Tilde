import Foundation

/// Shared copy for UserNotifications banners (side-of-screen alerts).
public enum AttentionBannerCopy {
    public static func title(for kind: AgentAttentionEventKind) -> String {
        switch kind {
        case .needsInput: return "Agent needs you"
        case .completed: return "Ready to review"
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
