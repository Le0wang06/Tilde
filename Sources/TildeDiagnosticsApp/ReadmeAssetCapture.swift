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

        let left = "Tilde" as NSString
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

        let display = (title.isEmpty ? "$—" : title) as NSString
        let needsAttention = (title as NSString).contains("!")
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: needsAttention
                ? NSColor.systemOrange
                : NSColor.white.withAlphaComponent(0.95),
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

        // Soft charcoal → slate wash (not flat, not purple).
        if let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1),
            NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.15, alpha: 1),
            NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1),
        ]) {
            gradient.draw(in: NSRect(origin: .zero, size: size), angle: 125)
        }

        // Quiet grid texture.
        NSColor.white.withAlphaComponent(0.03).setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 1
        for x in stride(from: 0.0, through: size.width, by: 48) {
            grid.move(to: NSPoint(x: x, y: 0))
            grid.line(to: NSPoint(x: x, y: size.height))
        }
        for y in stride(from: 0.0, through: size.height, by: 48) {
            grid.move(to: NSPoint(x: 0, y: y))
            grid.line(to: NSPoint(x: size.width, y: y))
        }
        grid.stroke()

        let logo = loadLogoImage()
        let logoSide: CGFloat = 96
        let brandX: CGFloat = 96
        let brandY = size.height * 0.58
        if let logo {
            logo.draw(
                in: NSRect(x: brandX, y: brandY, width: logoSide, height: logoSide),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        } else {
            let tilde = "~" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 92, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.95),
            ]
            tilde.draw(at: NSPoint(x: brandX, y: brandY + 8), withAttributes: attrs)
        }

        let name = "Tilde" as NSString
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 64, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.96),
        ]
        name.draw(at: NSPoint(x: brandX, y: brandY - 78), withAttributes: nameAttrs)

        let caption = "Know what needs you next — without leaving flow" as NSString
        let capAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.58),
        ]
        caption.draw(at: NSPoint(x: brandX, y: brandY - 120), withAttributes: capAttrs)

        let pitch = "Agents · exact checks · spend · machine health" as NSString
        let pitchAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.38),
        ]
        pitch.draw(at: NSPoint(x: brandX, y: brandY - 152), withAttributes: pitchAttrs)

        let maxPanelHeight = size.height * 0.78
        let scale = min(380 / panel.size.width, maxPanelHeight / panel.size.height)
        let drawSize = NSSize(width: panel.size.width * scale, height: panel.size.height * scale)
        let origin = NSPoint(
            x: size.width - drawSize.width - 72,
            y: (size.height - drawSize.height) / 2
        )

        // Soft panel shadow.
        NSColor.black.withAlphaComponent(0.35).setFill()
        let shadow = NSBezierPath(
            roundedRect: NSRect(
                x: origin.x + 10,
                y: origin.y - 12,
                width: drawSize.width,
                height: drawSize.height
            ),
            xRadius: 18,
            yRadius: 18
        )
        shadow.fill()

        panel.draw(
            in: NSRect(origin: origin, size: drawSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        image.unlockFocus()
        writePNG(image, to: url)
    }

    private static func loadLogoImage() -> NSImage? {
        let root = findRepoRoot()
        let candidates = [
            root.appendingPathComponent("Docs/assets/tilde-logo.png"),
            root.appendingPathComponent("Sources/TildeDiagnosticsApp/Resources/tilde-logo.png"),
            Bundle.main.url(forResource: "tilde-logo", withExtension: "png"),
        ].compactMap { $0 }
        for url in candidates {
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
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
