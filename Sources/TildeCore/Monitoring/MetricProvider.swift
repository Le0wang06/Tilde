import Foundation

public protocol MetricProvider: Sendable {
    associatedtype Snapshot: Sendable

    func fetchSnapshot() async throws -> Snapshot
}

public protocol StreamingMetricProvider: Sendable {
    associatedtype Snapshot: Sendable

    func snapshots() -> AsyncStream<Snapshot>
}

public protocol AdvancedSensorProvider: Sendable {
    func cpuTemperature() async throws -> Double?
    func gpuUsage() async throws -> Double?
    func fanSpeeds() async throws -> [FanReading]?
}
