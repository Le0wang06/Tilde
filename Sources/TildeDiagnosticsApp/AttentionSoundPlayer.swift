import AppKit
import TildeCore

/// Local menu-bar ping so attention is audible even when notification
/// permission is denied or banners are quiet.
enum AttentionSoundPlayer {
    static func play(for events: [AgentAttentionEvent]) {
        guard !events.isEmpty else { return }
        let urgent = events.contains { $0.kind == .needsInput }
        // System sounds shipped with macOS — no bundled assets required.
        let name = urgent ? "Tink" : "Purr"
        NSSound(named: NSSound.Name(name))?.play()
    }
}
