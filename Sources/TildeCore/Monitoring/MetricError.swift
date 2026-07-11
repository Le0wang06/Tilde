import Foundation

public enum MetricError: LocalizedError, Sendable {
    case unavailable(String)
    case systemCall(String, code: Int32)
    case invalidResponse(String)
    case executableNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .systemCall(let name, let code): "\(name) failed with code \(code)"
        case .invalidResponse(let reason): "Invalid response: \(reason)"
        case .executableNotFound(let name): "\(name) is not installed or is not on PATH"
        }
    }
}
