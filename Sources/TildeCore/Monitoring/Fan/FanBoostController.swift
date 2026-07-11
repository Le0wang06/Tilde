import Foundation

/// Fan boost preference for Tilde.
/// Modern Macs manage fans in firmware with no stable public write API, so
/// enabling boost activates software-assist mode: Tilde keeps sampling thermal
/// state aggressively and drives the menu-bar fan animation while macOS
/// continues owning actual RPM.
public actor FanBoostController {
    public enum Mode: String, Sendable, Equatable {
        case off
        case softwareAssist
    }

    public struct Snapshot: Sendable, Equatable {
        public var isEnabled: Bool
        public var mode: Mode
        public var statusText: String
        public var detailText: String

        public static let idle = Snapshot(
            isEnabled: false,
            mode: .off,
            statusText: "Off",
            detailText: "Tap to boost cooling"
        )
    }

    private var enabled = false

    public init() {}

    public func currentSnapshot(thermalState: TildeThermalState = .unavailable) -> Snapshot {
        if !enabled {
            return .idle
        }
        return Snapshot(
            isEnabled: true,
            mode: .softwareAssist,
            statusText: "Boost On",
            detailText: detail(for: thermalState)
        )
    }

    public func setEnabled(_ on: Bool, thermalState: TildeThermalState) -> Snapshot {
        enabled = on
        return currentSnapshot(thermalState: thermalState)
    }

    private func detail(for thermalState: TildeThermalState) -> String {
        switch thermalState {
        case .nominal:
            return "System cooling · Nominal"
        case .fair:
            return "System cooling · Fair"
        case .serious:
            return "System cooling · Elevated"
        case .critical:
            return "System cooling · Critical"
        case .unavailable:
            return "macOS manages fan speed"
        }
    }
}
