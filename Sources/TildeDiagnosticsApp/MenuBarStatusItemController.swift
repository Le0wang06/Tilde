import AppKit
import SwiftUI

/// AppKit status item so today's AI spend is always visible as text
/// in the macOS menu bar (SwiftUI MenuBarExtra often hides titles).
@MainActor
final class MenuBarStatusItemController: NSObject {
    static let shared = MenuBarStatusItemController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var model: DiagnosticViewModel?
    private var titleObserver: NSObjectProtocol?

    func install(model: DiagnosticViewModel) {
        self.model = model

        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            item.button?.toolTip = "Tilde — daily AI cost"
            item.button?.target = self
            item.button?.action = #selector(togglePopover(_:))
            statusItem = item
        }

        updateTitle(model.menuBarTitle, needsAttention: model.agentAttention.attentionCount > 0)

        if popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            // Fit content tightly — a fixed tall size left an empty gap under the panel.
            popover.contentSize = NSSize(width: 332, height: 420)
            let root = MenuBarPanel()
                .environmentObject(model)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: PanelSizeKey.self, value: proxy.size)
                    }
                )
                .onPreferenceChange(PanelSizeKey.self) { size in
                    guard size.width > 0, size.height > 0 else { return }
                    let height = min(ceil(size.height), 460)
                    self.popover?.contentSize = NSSize(
                        width: ceil(size.width),
                        height: height
                    )
                }
            let host = NSHostingController(rootView: root)
            host.sizingOptions = [.preferredContentSize]
            popover.contentViewController = host
            self.popover = popover
        }

        if titleObserver == nil {
            titleObserver = NotificationCenter.default.addObserver(
                forName: .tildeMenuBarTitleDidChange,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let title = notification.userInfo?["title"] as? String ?? "$—"
                let needsAttention = notification.userInfo?["needsAttention"] as? Bool ?? false
                Task { @MainActor in
                    self?.updateTitle(title, needsAttention: needsAttention)
                }
            }
        }
    }

    func updateTitle(_ title: String, needsAttention: Bool = false) {
        statusItem?.button?.title = title
        statusItem?.button?.toolTip = needsAttention
            ? "Tilde — agent needs your attention"
            : "Tilde — daily AI cost"
        // Subtle emphasis when something needs you; keep spend readable.
        statusItem?.button?.appearsDisabled = false
        if needsAttention {
            statusItem?.button?.contentTintColor = .systemOrange
        } else {
            statusItem?.button?.contentTintColor = nil
        }
    }

    func showPopover() {
        guard let button = statusItem?.button, let popover else { return }
        model?.startIfNeeded()
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            model?.startIfNeeded()
            // Show only the status-item panel — do not activate the app or
            // bring any main diagnostics window forward.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

extension Notification.Name {
    static let tildeMenuBarTitleDidChange = Notification.Name("tildeMenuBarTitleDidChange")
    static let tildeOpenMainWindow = Notification.Name("tildeOpenMainWindow")
    static let tildeHandleDeepLink = Notification.Name("tildeHandleDeepLink")
}

private struct PanelSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
