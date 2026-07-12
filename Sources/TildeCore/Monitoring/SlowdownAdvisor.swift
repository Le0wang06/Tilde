import Foundation
import UserNotifications

public enum SlowdownSeverity: String, Sendable, Equatable {
    case none
    case warn
    case critical
}

public struct SlowdownAdvice: Sendable, Equatable {
    public var severity: SlowdownSeverity
    public var title: String
    public var detail: String

    public static let none = SlowdownAdvice(
        severity: .none,
        title: "",
        detail: ""
    )

    public init(severity: SlowdownSeverity, title: String, detail: String) {
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}

public enum SlowdownAdvisor {
    public static func advice(from system: SystemSnapshot) -> SlowdownAdvice {
        let thermal = system.thermalState
        let pressure: MemoryPressure
        if case .available(let memory) = system.memory {
            pressure = memory.pressure
        } else {
            pressure = .unavailable
        }

        if thermal == .critical || pressure == .critical {
            return SlowdownAdvice(
                severity: .critical,
                title: "Machine is thrashing",
                detail: thermal == .critical
                    ? "Thermal critical — expect jank; consider Fan Boost or pausing heavy builds."
                    : "Memory pressure critical — indexing and agents will slow down."
            )
        }

        if thermal == .serious || pressure == .warning {
            return SlowdownAdvice(
                severity: .warn,
                title: "Slowdown risk",
                detail: thermal == .serious
                    ? "Thermals elevated — long builds may stretch."
                    : "Memory pressure elevated — close heavy apps if agents feel sluggish."
            )
        }

        if thermal == .fair {
            return SlowdownAdvice(
                severity: .warn,
                title: "Warming up",
                detail: "Thermal state is fair — keep an eye on fan noise and build times."
            )
        }

        return .none
    }
}

@MainActor
public final class SlowdownNotifier {
    private var lastPostedKey: String?

    public init() {}

    public func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public func postIfNeeded(_ advice: SlowdownAdvice) {
        guard advice.severity == .critical || advice.severity == .warn else {
            lastPostedKey = nil
            return
        }
        let key = "\(advice.severity.rawValue)|\(advice.title)"
        guard key != lastPostedKey else { return }
        lastPostedKey = key

        let content = UNMutableNotificationContent()
        content.title = "Tilde · \(advice.title)"
        content.body = advice.detail
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "tilde.slowdown.\(advice.severity.rawValue)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
