import Foundation
import UserNotifications

@MainActor
public final class AgentAttentionNotifier {
    public static let categoryIdentifier = "tilde.attention"

    private var authorizationRequested = false

    public init() {}

    public func post(
        _ events: [AgentAttentionEvent],
        logoAttachment: UNNotificationAttachment? = nil
    ) {
        guard !events.isEmpty else { return }
        requestAuthorizationIfNeeded()

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            // Don't enqueue banners until the user has allowed them — otherwise
            // macOS may drop the first alerts with no visible error.
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }

            for event in events {
                let content = UNMutableNotificationContent()
                content.title = AttentionBannerCopy.title(for: event.kind, state: event.agent.state)
                content.subtitle = "Tilde"
                content.body = AttentionBannerCopy.body(for: event.agent)
                content.sound = .default
                content.categoryIdentifier = Self.categoryIdentifier
                content.threadIdentifier = "tilde.attention"
                // Stay on .active — .timeSensitive needs an entitlement this
                // unsigned menu-bar build does not have, and can fail delivery.
                content.userInfo = [
                    "terminalID": event.agent.terminalID,
                    "kind": event.kind.rawValue,
                    "projectName": event.agent.projectName,
                ]
                if let logoAttachment {
                    content.attachments = [logoAttachment]
                }

                let request = UNNotificationRequest(
                    identifier: AttentionBannerCopy.requestID(for: event),
                    content: content,
                    trigger: nil
                )
                UNUserNotificationCenter.current().add(request) { error in
                    if let error {
                        NSLog("Tilde attention banner failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
