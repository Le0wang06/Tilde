import Foundation

public struct ThermalProvider: MetricProvider {
    public init() {}

    public func fetchSnapshot() async throws -> TildeThermalState {
        try Task.checkCancellation()
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unavailable
        }
    }
}
