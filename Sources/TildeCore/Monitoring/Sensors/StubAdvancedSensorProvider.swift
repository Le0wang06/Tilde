import Foundation

public struct StubAdvancedSensorProvider: AdvancedSensorProvider {
    public static let unavailableReason = "No stable public macOS API is available for this metric on all Macs"

    public init() {}

    public func cpuTemperature() async throws -> Double? { nil }
    public func gpuUsage() async throws -> Double? { nil }
    public func fanSpeeds() async throws -> [FanReading]? { nil }

    public func fetchSnapshot() async -> AdvancedSensorSnapshot {
        AdvancedSensorSnapshot(
            cpuTemperature: .unavailable(reason: Self.unavailableReason),
            gpuUsage: .unavailable(reason: Self.unavailableReason),
            fanSpeeds: .unavailable(reason: Self.unavailableReason)
        )
    }
}
