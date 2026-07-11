import Foundation

public actor MonitoringCoordinator {
    private let cpuProvider: CPUProvider
    private let memoryProvider: MemoryProvider
    private let storageProvider: StorageProvider
    private let networkProvider: NetworkProvider
    private let batteryProvider: BatteryProvider
    private let thermalProvider: ThermalProvider
    private let sensorProvider: StubAdvancedSensorProvider
    private let codexProvider: CodexAppServerProbe

    public init(
        cpuProvider: CPUProvider = CPUProvider(),
        memoryProvider: MemoryProvider = MemoryProvider(),
        storageProvider: StorageProvider = StorageProvider(),
        networkProvider: NetworkProvider = NetworkProvider(),
        batteryProvider: BatteryProvider = BatteryProvider(),
        thermalProvider: ThermalProvider = ThermalProvider(),
        sensorProvider: StubAdvancedSensorProvider = StubAdvancedSensorProvider(),
        codexProvider: CodexAppServerProbe = CodexAppServerProbe()
    ) {
        self.cpuProvider = cpuProvider
        self.memoryProvider = memoryProvider
        self.storageProvider = storageProvider
        self.networkProvider = networkProvider
        self.batteryProvider = batteryProvider
        self.thermalProvider = thermalProvider
        self.sensorProvider = sensorProvider
        self.codexProvider = codexProvider
    }

    public func runDiagnostics() async -> DiagnosticReport {
        async let system = runSystemDiagnostics()
        async let codex = runCodexDiagnostics()
        return await DiagnosticReport(system: system, codex: codex)
    }

    public func runSystemDiagnostics() async -> SystemSnapshot {
        await sampleSystem(previous: nil, metrics: Set(LiveMetric.allCases.filter { $0 != .codex }))
    }

    public func runCodexDiagnostics() async -> Availability<CodexDiagnosticSnapshot> {
        await capture { try await self.codexProvider.fetchSnapshot() }
    }

    public func sampleSystem(previous: SystemSnapshot?, metrics: Set<LiveMetric>) async -> SystemSnapshot {
        async let cpu = sample(metrics.contains(.cpu)) { try await self.cpuProvider.fetchSnapshot() }
        async let memory = sample(metrics.contains(.memory)) { try await self.memoryProvider.fetchSnapshot() }
        async let storage = sample(metrics.contains(.storage)) { try await self.storageProvider.fetchSnapshot() }
        async let network = sample(metrics.contains(.network)) { try await self.networkProvider.fetchSnapshot() }
        async let battery = sample(metrics.contains(.battery)) { try await self.batteryProvider.fetchSnapshot() }
        async let thermal = sample(metrics.contains(.thermal)) { try await self.thermalProvider.fetchSnapshot() }
        async let sensors = metrics.contains(.advancedSensors) ? sensorProvider.fetchSnapshot() : nil

        let thermalResult = await thermal
        let thermalState: TildeThermalState
        switch thermalResult {
        case .available(let value):
            thermalState = value
        case .unavailable, .failed:
            thermalState = .unavailable
        case nil:
            thermalState = previous?.thermalState ?? .unavailable
        }
        let sensorResult = await sensors
        let advancedSensors: AdvancedSensorSnapshot
        if let sensorResult {
            advancedSensors = sensorResult
        } else if let previous {
            advancedSensors = previous.advancedSensors
        } else {
            advancedSensors = await sensorProvider.fetchSnapshot()
        }

        return await SystemSnapshot(
            timestamp: Date(),
            cpu: cpu ?? previous?.cpu ?? waiting("CPU"),
            memory: memory ?? previous?.memory ?? waiting("Memory"),
            storage: storage ?? previous?.storage ?? waiting("Storage"),
            network: network ?? previous?.network ?? waiting("Network"),
            battery: battery ?? previous?.battery ?? waiting("Battery"),
            thermalState: thermalState,
            advancedSensors: advancedSensors
        )
    }

    private func sample<Value: Sendable>(
        _ requested: Bool,
        operation: sending @escaping @Sendable () async throws -> Value
    ) async -> Availability<Value>? {
        guard requested else { return nil }
        return await capture(operation)
    }

    private func waiting<Value: Sendable>(_ name: String) -> Availability<Value> {
        .unavailable(reason: "Waiting for first \(name.lowercased()) sample")
    }

    private func capture<Value: Sendable>(
        _ operation: sending @escaping @Sendable () async throws -> Value
    ) async -> Availability<Value> {
        do {
            return .available(try await operation())
        } catch is CancellationError {
            return .failed(message: "Cancelled")
        } catch let error as MetricError {
            switch error {
            case .unavailable(let reason), .executableNotFound(let reason):
                return .unavailable(reason: reason)
            default:
                return .failed(message: error.localizedDescription)
            }
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }
}
