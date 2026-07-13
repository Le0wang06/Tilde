import Foundation
import UserNotifications

@MainActor
public final class AgentAttentionNotifier {
    public static let categoryIdentifier = "tilde.attention"

    private var authorizationRequested = false

    public init() {}

    public func post(_ events: [AgentAttentionEvent]) {
        guard !events.isEmpty else { return }
        requestAuthorizationIfNeeded()

        for event in events {
            let content = UNMutableNotificationContent()
            content.title = AttentionBannerCopy.title(for: event.kind)
            content.subtitle = "Tilde"
            content.body = AttentionBannerCopy.body(for: event.agent)
            content.sound = .default
            content.categoryIdentifier = Self.categoryIdentifier
            content.threadIdentifier = "tilde.attention"
            content.userInfo = [
                "terminalID": event.agent.terminalID,
                "kind": event.kind.rawValue,
                "projectName": event.agent.projectName,
            ]
            if #available(macOS 12.0, *) {
                content.interruptionLevel = event.kind == .needsInput ? .timeSensitive : .active
            }

            let request = UNNotificationRequest(
                identifier: AttentionBannerCopy.requestID(for: event),
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
