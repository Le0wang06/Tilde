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
        async let cpu = capture { try await self.cpuProvider.fetchSnapshot() }
        async let memory = capture { try await self.memoryProvider.fetchSnapshot() }
        async let storage = capture { try await self.storageProvider.fetchSnapshot() }
        async let network = capture { try await self.networkProvider.fetchSnapshot() }
        async let battery = capture { try await self.batteryProvider.fetchSnapshot() }
        async let thermal = capture { try await self.thermalProvider.fetchSnapshot() }
        async let sensors = sensorProvider.fetchSnapshot()
        async let codex = capture { try await self.codexProvider.fetchSnapshot() }

        let thermalResult = await thermal
        let thermalState: TildeThermalState
        switch thermalResult {
        case .available(let value): thermalState = value
        case .unavailable, .failed: thermalState = .unavailable
        }

        let system = await SystemSnapshot(
            timestamp: Date(),
            cpu: cpu,
            memory: memory,
            storage: storage,
            network: network,
            battery: battery,
            thermalState: thermalState,
            advancedSensors: sensors
        )
        return await DiagnosticReport(system: system, codex: codex)
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
