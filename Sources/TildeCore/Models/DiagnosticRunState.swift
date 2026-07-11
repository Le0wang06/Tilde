import Foundation

public enum DiagnosticRunEvent: Sendable {
    case start
    case finish
    case fail
    case cancel
}

public enum DiagnosticRunState: Equatable, Sendable {
    case idle
    case running
    case completed
    case failed
    case cancelled

    public mutating func apply(_ event: DiagnosticRunEvent) {
        switch event {
        case .start:
            self = .running
        case .finish where self == .running:
            self = .completed
        case .fail where self == .running:
            self = .failed
        case .cancel where self == .running:
            self = .cancelled
        case .finish, .fail, .cancel:
            break
        }
    }
}
