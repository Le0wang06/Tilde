import Foundation

public struct ThermalProvider: MetricProvider {
    public init() {}

    public func fetchSnapshot() async throws -> TildeThermalState {
        try Task.checkCancellation()
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return TildeThermalState.nominal
        case .fair: return TildeThermalState.fair
        case .serious: return TildeThermalState.serious
        case .critical: return TildeThermalState.critical
        @unknown default: return TildeThermalState.unavailable
        }
    }
}
