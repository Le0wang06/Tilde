import AppKit
import UserNotifications
import TildeCore

/// Makes attention alerts show as native macOS side banners for the
/// menu-bar app, and routes clicks back into the status-item panel.
@MainActor
final class AttentionBannerCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AttentionBannerCenter()

    static let categoryID = "tilde.attention"
    static let openActionID = "tilde.attention.open"

    private weak var model: DiagnosticViewModel?

    func install(model: DiagnosticViewModel) {
        self.model = model
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let open = UNNotificationAction(
            identifier: Self.openActionID,
            title: "Open",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [open],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("Tilde notification authorization error: \(error.localizedDescription)")
            } else if !granted {
                NSLog("Tilde notification authorization denied — side banners will not appear")
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Accessory / LSUIElement apps are often treated as foreground.
        // Always surface the side banner so attention isn't silent.
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let terminalID = response.notification.request.content.userInfo["terminalID"] as? String
        completionHandler()
        Task { @MainActor in
            self.handleTap(terminalID: terminalID)
        }
    }

    private func handleTap(terminalID: String?) {
        model?.startIfNeeded()
        if let terminalID,
           let agent = model?.agentAttention.agents.first(where: { $0.terminalID == terminalID }) {
            model?.focusAgent(agent)
        }
        MenuBarStatusItemController.shared.showPopover()
    }
}
