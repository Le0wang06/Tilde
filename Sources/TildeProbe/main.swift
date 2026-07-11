import Foundation
import TildeCore

@main
struct TildeProbe {
    static func main() async {
        let report = await MonitoringCoordinator().runDiagnostics()
        print("Tilde Phase 0 Feasibility")
        print("CPU                  \(status(report.system.cpu))")
        print("Memory               \(status(report.system.memory))")
        print("Storage              \(status(report.system.storage))")
        print("Network              \(status(report.system.network))")
        print("Battery              \(status(report.system.battery))")
        print("Thermal State        \(report.system.thermalState == .unavailable ? "Unavailable" : "Working")")
        print("CPU Temperature      \(status(report.system.advancedSensors.cpuTemperature))")
        print("GPU                   \(status(report.system.advancedSensors.gpuUsage))")
        print("Fan                   \(status(report.system.advancedSensors.fanSpeeds))")
        print("Codex Connection      \(status(report.codex))")

        if case .available(let codex) = report.codex {
            print("Codex Authentication  \(codex.isAuthenticated ? "Working" : "Required")")
            print("Codex Usage           \(codex.primaryLimit == nil ? "Unavailable" : "Working")")
            print("Codex Tokens Today    \(codex.tokensToday == nil ? "Unavailable" : "Working")")
            print("Codex Threads         \(codex.threadCount == nil ? "Unavailable" : "Working")")
            for note in codex.notes {
                print("Codex Note            \(note)")
            }
        }
    }

    private static func status<Value>(_ availability: Availability<Value>) -> String {
        switch availability {
        case .available: "Working"
        case .unavailable(let reason): "Unavailable (\(reason))"
        case .failed(let message): "Failed (\(message))"
        }
    }
}
