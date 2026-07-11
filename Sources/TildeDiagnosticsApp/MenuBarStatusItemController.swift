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
            popover.contentSize = NSSize(width: 388, height: 520)
            let host = NSHostingController(
                rootView: MenuBarPanel()
                    .environmentObject(model)
            )
            host.view.wantsLayer = true
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
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

extension Notification.Name {
    static let tildeMenuBarTitleDidChange = Notification.Name("tildeMenuBarTitleDidChange")
    static let tildeOpenMainWindow = Notification.Name("tildeOpenMainWindow")
}
