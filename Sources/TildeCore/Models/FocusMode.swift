import Foundation

public enum FocusMode: String, CaseIterable, Sendable, Equatable {
    case off
    case ship
    case meet
    case battery

    public var title: String {
        switch self {
        case .off: return "Off"
        case .ship: return "Ship"
        case .meet: return "Meet"
        case .battery: return "Battery"
        }
    }

    public var detail: String {
        switch self {
        case .off:
            return "No focus preset"
        case .ship:
            return "Fans boosted for long builds and agent runs"
        case .meet:
            return "Quiet fans; quit Slack/Discord helpers if running"
        case .battery:
            return "Fans off and cooler defaults for on-battery work"
        }
    }

    /// Target fan boost enabled state when applying this mode. `nil` means leave alone.
    public var fanEnabled: Bool? {
        switch self {
        case .off: return nil
        case .ship: return true
        case .meet, .battery: return false
        }
    }

    public var fanSpeed: Double? {
        switch self {
        case .off: return nil
        case .ship: return 0.9
        case .meet: return 0.4
        case .battery: return 0.25
        }
    }

    /// Bundle IDs quit when entering Meet (user-initiated).
    public var quitBundleIDs: [String] {
        switch self {
        case .meet:
            return [
                "com.tinyspeck.slackmacgap",
                "com.hnc.Discord",
            ]
        default:
            return []
        }
    }
}
