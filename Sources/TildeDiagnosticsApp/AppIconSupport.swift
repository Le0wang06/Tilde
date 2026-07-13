import AppKit
import Foundation
import UserNotifications

enum AppIconSupport {
    /// Apply the bundled Tilde mark as the running app icon so Notification
    /// Center / Launch Services stop using the generic grid placeholder.
    @MainActor
    static func applyApplicationIcon() {
        guard let image = loadIconImage() else { return }
        NSApp.applicationIconImage = image
    }

    static func loadIconImage() -> NSImage? {
        if let url = resourceURL(name: "AppIcon", ext: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let url = resourceURL(name: "tilde-logo", ext: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return nil
    }

    static func resourceURL(name: String, ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }
        // Installed menu-bar builds resolve Resources next to the executable.
        let exe = Bundle.main.bundleURL
        let candidates = [
            exe.appendingPathComponent("Contents/Resources/\(name).\(ext)"),
            exe.deletingLastPathComponent().appendingPathComponent("Resources/\(name).\(ext)"),
            exe
                .deletingLastPathComponent() // MacOS
                .deletingLastPathComponent() // Contents
                .appendingPathComponent("Resources/\(name).\(ext)"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Notification Center shows a second image from attachments; also helps
    /// when the system still caches a blank app icon.
    static func makeLogoAttachment() -> UNNotificationAttachment? {
        guard let source = resourceURL(name: "tilde-logo", ext: "png")
                ?? resourceURL(name: "AppIcon", ext: "icns") else { return nil }
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tilde-notify-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let dest = tmpDir.appendingPathComponent("logo.png")
            if source.pathExtension.lowercased() == "png" {
                try FileManager.default.copyItem(at: source, to: dest)
            } else if let image = NSImage(contentsOf: source),
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: dest)
            } else {
                return nil
            }
            return try UNNotificationAttachment(
                identifier: "tilde-logo",
                url: dest,
                options: [UNNotificationAttachmentOptionsTypeHintKey: "public.png"]
            )
        } catch {
            NSLog("Tilde logo attachment failed: \(error.localizedDescription)")
            return nil
        }
    }
}
