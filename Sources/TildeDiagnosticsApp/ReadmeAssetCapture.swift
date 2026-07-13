import AppKit
import SwiftUI

/// Captures real on-screen UI for README assets when launched with `--capture-readme`.
@MainActor
enum ReadmeAssetCapture {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--capture-readme")
    }

    static func runIfRequested(model: DiagnosticViewModel) {
        guard isRequested else { return }
        Task { @MainActor in
            await capture(model: model)
        }
    }

    private static func capture(model: DiagnosticViewModel) async {
        model.startIfNeeded()
        NSApp.appearance = NSAppearance(named: .darkAqua)

        for _ in 0..<40 {
            if model.report != nil { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        // Let a few live samples fill the sparkline.
        try? await Task.sleep(for: .seconds(3))
        model.applyReadmeDemoStubs()
        try? await Task.sleep(for: .milliseconds(200))

        let repoRoot = findRepoRoot()
        let outDir = repoRoot.appendingPathComponent("Docs/assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let panelURL = outDir.appendingPathComponent("tilde-panel-dark.png")
        let menuURL = outDir.appendingPathComponent("tilde-menubar.png")

        // Exact panel render (full unscrolled height while capturing).
        if let panelImage = renderPanel(model: model) {
            writePNG(panelImage, to: panelURL)
        }

        // Also try a live popover window capture; keep whichever is taller.
        MenuBarStatusItemController.shared.showPopover()
        try? await Task.sleep(for: .milliseconds(900))
        let liveURL = outDir.appendingPathComponent("tilde-panel-live.png")
        if let window = popoverWindow() {
            captureWindow(window.windowNumber, to: liveURL)
            if let live = NSImage(contentsOf: liveURL),
               let panel = NSImage(contentsOf: panelURL),
               live.size.height >= panel.size.height - 1 {
                try? FileManager.default.removeItem(at: panelURL)
                try? FileManager.default.moveItem(at: liveURL, to: panelURL)
            } else {
                try? FileManager.default.removeItem(at: liveURL)
            }
        }

        writeMenuBar(title: model.menuBarTitle, to: menuURL)

        if let panel = NSImage(contentsOf: panelURL) {
            writeHero(panel: panel, to: outDir.appendingPathComponent("tilde-hero.png"))
        }

        print("README assets written to \(outDir.path)")
        NSApp.terminate(nil)
    }

    private static func popoverWindow() -> NSWindow? {
        let visible = NSApp.windows.filter(\.isVisible)
        // Prefer the narrow popover-sized window.
        if let match = visible.first(where: { $0.frame.width >= 300 && $0.frame.width <= 400 && $0.frame.height >= 240 }) {
            return match
        }
        return visible
            .filter { !$0.className.contains("NSStatusBar") }
            .max(by: { $0.frame.height < $1.frame.height })
    }

    private static func renderPanel(model: DiagnosticViewModel) -> NSImage? {
        let root = MenuBarPanel()
            .environmentObject(model)
            .frame(width: 332)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: 332, height: 10)

        host.layoutSubtreeIfNeeded()
        var fitting = host.fittingSize
        if fitting.height < 100 {
            // First pass can be undersized before SwiftUI settles.
            host.frame = NSRect(x: 0, y: 0, width: 332, height: 1200)
            host.layoutSubtreeIfNeeded()
            fitting = host.fittingSize
        }
        let height = max(fitting.height, 320)
        host.frame = NSRect(x: 0, y: 0, width: 332, height: height)
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func writePNG(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func captureWindow(_ windowID: Int, to url: URL) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-x", "-l\(windowID)", url.path]
        try? proc.run()
        proc.waitUntilExit()
    }

    private static func writeMenuBar(title: String, to url: URL) {
        let size = NSSize(width: 1800, height: 52)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        // Subtle bottom edge like the real menu bar.
        NSColor.white.withAlphaComponent(0.08).setStroke()
        let edge = NSBezierPath()
        edge.move(to: NSPoint(x: 0, y: 0.5))
        edge.line(to: NSPoint(x: size.width, y: 0.5))
        edge.lineWidth = 1
        edge.stroke()

        let apple = "" as NSString
        let appleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        apple.draw(at: NSPoint(x: 16, y: 16), withAttributes: appleAttrs)

        let left = "TildeDiagnostics" as NSString
        let leftAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        left.draw(at: NSPoint(x: 40, y: 16), withAttributes: leftAttrs)

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE  MMM d  h:mm a"
        let trailing = formatter.string(from: Date()) as NSString
        let trailAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.75),
        ]
        let trailSize = trailing.size(withAttributes: trailAttrs)
        let trailingX = size.width - trailSize.width - 16

        let display = (title.isEmpty ? "~ …" : title) as NSString
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        ]
        let titleSize = display.size(withAttributes: titleAttrs)
        display.draw(
            at: NSPoint(x: trailingX - titleSize.width - 24, y: 16),
            withAttributes: titleAttrs
        )

        trailing.draw(
            at: NSPoint(x: trailingX, y: 17),
            withAttributes: trailAttrs
        )

        image.unlockFocus()
        writePNG(image, to: url)
    }

    private static func writeHero(panel: NSImage, to url: URL) {
        let size = NSSize(width: 1600, height: 900)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        let tilde = "~" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 120, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]
        let textSize = tilde.size(withAttributes: attrs)
        tilde.draw(
            at: NSPoint(x: (size.width - textSize.width) / 2, y: size.height * 0.62),
            withAttributes: attrs
        )

        let caption = "menu-bar command center" as NSString
        let capAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55),
        ]
        let capSize = caption.size(withAttributes: capAttrs)
        caption.draw(
            at: NSPoint(x: (size.width - capSize.width) / 2, y: size.height * 0.52),
            withAttributes: capAttrs
        )

        let maxPanelHeight = size.height * 0.72
        let scale = min(360 / panel.size.width, maxPanelHeight / panel.size.height)
        let drawSize = NSSize(width: panel.size.width * scale, height: panel.size.height * scale)
        let origin = NSPoint(
            x: size.width - drawSize.width - 80,
            y: (size.height - drawSize.height) / 2
        )
        panel.draw(
            in: NSRect(origin: origin, size: drawSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        image.unlockFocus()
        writePNG(image, to: url)
    }

    private static func findRepoRoot() -> URL {
        var url = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        for _ in 0..<10 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
