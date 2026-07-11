import Foundation

public enum Availability<Value: Sendable>: Sendable {
    case available(Value)
    case unavailable(reason: String)
    case failed(message: String)
}

public enum MemoryPressure: String, Codable, Sendable {
    case normal
    case warning
    case critical
    case unavailable
}

public enum TildeThermalState: String, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unavailable
}

public struct FanReading: Codable, Equatable, Sendable {
    public let identifier: String
    public let rpm: Int

    public init(identifier: String, rpm: Int) {
        self.identifier = identifier
        self.rpm = rpm
    }
}

public struct CPUReading: Sendable {
    public let usagePercent: Double

    public init(usagePercent: Double) {
        self.usagePercent = usagePercent
    }
}

public struct MemoryReading: Sendable {
    public let usedBytes: UInt64
    public let totalBytes: UInt64
    public let swapUsedBytes: UInt64
    public let pressure: MemoryPressure

    public init(usedBytes: UInt64, totalBytes: UInt64, swapUsedBytes: UInt64, pressure: MemoryPressure) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.swapUsedBytes = swapUsedBytes
        self.pressure = pressure
    }
}

public struct StorageReading: Sendable {
    public let usedBytes: UInt64
    public let totalBytes: UInt64

    public init(usedBytes: UInt64, totalBytes: UInt64) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
    }
}

public struct NetworkReading: Sendable {
    public let downloadBytesPerSecond: Double?
    public let uploadBytesPerSecond: Double?
    public let localIPAddress: String?
    public let interfaceName: String?

    public init(
        downloadBytesPerSecond: Double?,
        uploadBytesPerSecond: Double?,
        localIPAddress: String?,
        interfaceName: String?
    ) {
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.localIPAddress = localIPAddress
        self.interfaceName = interfaceName
    }
}

public struct BatteryReading: Sendable {
    public let percent: Double?
    public let isCharging: Bool?
    public let isOnACPower: Bool
    public let estimatedMinutesRemaining: Int?

    public init(percent: Double?, isCharging: Bool?, isOnACPower: Bool, estimatedMinutesRemaining: Int?) {
        self.percent = percent
        self.isCharging = isCharging
        self.isOnACPower = isOnACPower
        self.estimatedMinutesRemaining = estimatedMinutesRemaining
    }
}

public struct AdvancedSensorSnapshot: Sendable {
    public let cpuTemperature: Availability<Double>
    public let gpuUsage: Availability<Double>
    public let fanSpeeds: Availability<[FanReading]>

    public init(
        cpuTemperature: Availability<Double>,
        gpuUsage: Availability<Double>,
        fanSpeeds: Availability<[FanReading]>
    ) {
        self.cpuTemperature = cpuTemperature
        self.gpuUsage = gpuUsage
        self.fanSpeeds = fanSpeeds
    }
}

public struct SystemSnapshot: Sendable {
    public let timestamp: Date
    public let cpu: Availability<CPUReading>
    public let memory: Availability<MemoryReading>
    public let storage: Availability<StorageReading>
    public let network: Availability<NetworkReading>
    public let battery: Availability<BatteryReading>
    public let thermalState: TildeThermalState
    public let advancedSensors: AdvancedSensorSnapshot

    public init(
        timestamp: Date,
        cpu: Availability<CPUReading>,
        memory: Availability<MemoryReading>,
        storage: Availability<StorageReading>,
        network: Availability<NetworkReading>,
        battery: Availability<BatteryReading>,
        thermalState: TildeThermalState,
        advancedSensors: AdvancedSensorSnapshot
    ) {
        self.timestamp = timestamp
        self.cpu = cpu
        self.memory = memory
        self.storage = storage
        self.network = network
        self.battery = battery
        self.thermalState = thermalState
        self.advancedSensors = advancedSensors
    }
}
