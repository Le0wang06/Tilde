import Foundation
import UserNotifications

@MainActor
public final class AgentAttentionNotifier {
    private var authorizationRequested = false

    public init() {}

    public func post(_ events: [AgentAttentionEvent]) {
        guard !events.isEmpty else { return }
        requestAuthorizationIfNeeded()

        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.kind == .needsInput
                ? "Tilde · Agent needs you"
                : "Tilde · Ready to review"
            content.body = "\(event.agent.projectName) · \(event.agent.agent.capitalized)"
            content.sound = event.kind == .needsInput ? .default : nil
            content.userInfo = ["terminalID": event.agent.terminalID]

            let request = UNNotificationRequest(
                identifier: "tilde-agent-\(event.kind.rawValue)-\(event.agent.terminalID)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
