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
        requestAuthorizationVisibly()
    }

    /// Menu-bar / LSUIElement apps often never show the Allow sheet unless
    /// they briefly become a normal activating app first.
    private func requestAuthorizationVisibly() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            Task { @MainActor in
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                try? await Task.sleep(for: .milliseconds(200))
                do {
                    // Prefer a real prompt; fall back to provisional so banners can
                    // still land quietly if the sheet never appears for LSUIElement.
                    let granted = try await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound])
                    if !granted {
                        _ = try? await UNUserNotificationCenter.current()
                            .requestAuthorization(options: [.alert, .sound, .provisional])
                    }
                } catch {
                    NSLog("Tilde notification authorization error: \(error.localizedDescription)")
                    _ = try? await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound, .provisional])
                }
                NSApp.setActivationPolicy(.accessory)
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
