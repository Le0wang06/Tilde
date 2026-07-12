import Foundation

public enum DeepLinkAction: Sendable, Equatable {
    case openWindow
    case refresh
    case copyStatus
    case openCursor
    case focus(FocusMode)

    public static func parse(url: URL) -> DeepLinkAction? {
        guard let scheme = url.scheme?.lowercased(), scheme == "tilde" else { return nil }
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let route = host.isEmpty ? path : (path.isEmpty ? host : "\(host)/\(path)")

        switch route {
        case "", "open", "window":
            return .openWindow
        case "refresh":
            return .refresh
        case "copy-status", "copystatus", "status":
            return .copyStatus
        case "open-cursor", "cursor":
            return .openCursor
        case "focus/ship", "ship":
            return .focus(.ship)
        case "focus/meet", "meet":
            return .focus(.meet)
        case "focus/battery", "battery":
            return .focus(.battery)
        case "focus/off", "focus":
            return .focus(.off)
        default:
            return nil
        }
    }

    public var exampleURL: String {
        switch self {
        case .openWindow: return "tilde://open"
        case .refresh: return "tilde://refresh"
        case .copyStatus: return "tilde://copy-status"
        case .openCursor: return "tilde://open-cursor"
        case .focus(let mode):
            switch mode {
            case .off: return "tilde://focus/off"
            case .ship: return "tilde://focus/ship"
            case .meet: return "tilde://focus/meet"
            case .battery: return "tilde://focus/battery"
            }
        }
    }
}
