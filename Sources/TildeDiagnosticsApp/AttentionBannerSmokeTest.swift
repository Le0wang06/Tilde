import AppKit
import UserNotifications
import TildeCore

/// Manual smoke trigger: `TildeDiagnostics --test-attention-banner`
/// Posts one native side banner, writes a result file, then quits.
@MainActor
enum AttentionBannerSmokeTest {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--test-attention-banner")
    }

    static func runIfRequested(model: DiagnosticViewModel) {
        guard isRequested else { return }
        Task { @MainActor in
            await run(model: model)
        }
    }

    private static func run(model: DiagnosticViewModel) async {
        AttentionBannerCenter.shared.install(model: model)

        let resultURL = URL(fileURLWithPath: "/tmp/tilde-attention-banner-smoke.txt")

        let center = UNUserNotificationCenter.current()
        center.delegate = AttentionBannerCenter.shared

        // Accessory apps often suppress the permission sheet — activate first.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .milliseconds(300))

        let granted: Bool = await withCheckedContinuation { cont in
            center.requestAuthorization(options: [.alert, .sound, .provisional]) { ok, error in
                if let error {
                    try? "auth-error: \(error.localizedDescription)".write(
                        to: resultURL, atomically: true, encoding: .utf8
                    )
                }
                cont.resume(returning: ok)
            }
        }

        NSApp.setActivationPolicy(.accessory)

        let authStatus: UNAuthorizationStatus = await withCheckedContinuation { cont in
            center.getNotificationSettings { settings in
                cont.resume(returning: settings.authorizationStatus)
            }
        }

        guard granted
                || authStatus == .authorized
                || authStatus == .provisional else {
            try? "denied status=\(authStatus.rawValue)".write(to: resultURL, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
            return
        }

        let agent = AgentAttentionItem(
            id: "smoke",
            terminalID: "smoke-term",
            paneID: nil,
            workspaceID: nil,
            agent: "codex",
            state: .blocked,
            cwd: "/tmp/demo-app",
            projectRoot: "/tmp/demo-app",
            projectName: "demo-app",
            branch: "feature/banners",
            focused: true
        )
        let event = AgentAttentionEvent(kind: .needsInput, agent: agent)

        let postError: String? = await withCheckedContinuation { cont in
            let content = UNMutableNotificationContent()
            content.title = AttentionBannerCopy.title(for: event.kind)
            content.subtitle = "Tilde"
            content.body = AttentionBannerCopy.body(for: event.agent)
            content.sound = .default
            content.categoryIdentifier = AgentAttentionNotifier.categoryIdentifier
            content.threadIdentifier = "tilde.attention"
            content.userInfo = ["terminalID": agent.terminalID]

            let request = UNNotificationRequest(
                identifier: "tilde-smoke-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request) { error in
                cont.resume(returning: error.map(\.localizedDescription))
            }
        }

        if let postError {
            try? "post-error: \(postError)".write(to: resultURL, atomically: true, encoding: .utf8)
        } else {
            try? "posted ok".write(to: resultURL, atomically: true, encoding: .utf8)
            AttentionSoundPlayer.play(for: [event])
        }

        // Keep the process alive long enough for the banner to paint.
        try? await Task.sleep(for: .seconds(6))
        NSApp.terminate(nil)
    }
}
