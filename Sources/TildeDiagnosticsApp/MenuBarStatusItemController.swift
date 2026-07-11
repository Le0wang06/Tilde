import AppKit
import SwiftUI

/// AppKit status item so the AI remaining % is always visible as text
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
            item.button?.toolTip = "Tilde — remaining allowance and tokens used today"
            item.button?.target = self
            item.button?.action = #selector(togglePopover(_:))
            statusItem = item
        }

        statusItem?.button?.title = model.menuBarTitle

        if popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            // Fit content tightly — a fixed tall size left an empty gap under the panel.
            popover.contentSize = NSSize(width: 384, height: 560)
            let root = MenuBarPanel()
                .environmentObject(model)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: PanelSizeKey.self, value: proxy.size)
                    }
                )
                .onPreferenceChange(PanelSizeKey.self) { size in
                    guard size.width > 0, size.height > 0 else { return }
                    self.popover?.contentSize = NSSize(
                        width: ceil(size.width),
                        height: ceil(size.height)
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
                let title = notification.userInfo?["title"] as? String ?? "~ …"
                Task { @MainActor in
                    self?.statusItem?.button?.title = title
                }
            }
        }
    }

    func updateTitle(_ title: String) {
        statusItem?.button?.title = title
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
}

private struct PanelSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
