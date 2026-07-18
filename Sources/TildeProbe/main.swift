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
        print("Claude Connection     \(status(report.claude))")

        let attention = await HerdrAgentProvider().snapshot()
        if attention.providerAvailable {
            print("Herdr Agents          Working (\(attention.agents.count) detected, \(attention.attentionCount) need attention)")
            for agent in attention.agents {
                print("Agent                 \(agent.projectName) · \(agent.agent) · \(agent.state.label)")
            }
        } else {
            print("Herdr Agents          Unavailable (\(attention.unavailableReason ?? "unknown reason"))")
        }

        let currentRoot = Self.gitRoot(at: FileManager.default.currentDirectoryPath)
        let verification = await VerificationService().snapshot(rootPath: currentRoot)
        let trust = await TrustPacketProvider().snapshot(
            rootPath: currentRoot,
            build: BuildPulseSnapshot(),
            ciStatus: .unknown,
            behind: nil,
            verification: verification
        )
        print("Trust Packet          \(trust.state.label) (\(trust.summary))")
        print("Exact Verification    \(verification.state.label) (\(verification.summary))")

        if case .available(let codex) = report.codex {
            print("Codex Authentication  \(codex.isAuthenticated ? "Working" : "Required")")
            print("Codex Usage           \(codex.rateLimitWindows.isEmpty ? "Unavailable" : "Working")")
            for window in codex.rateLimitWindows {
                print("Codex \(window.kind.compactLabel) Window   \(window.remainingPercent)% left")
            }
            print("Codex Tokens Today    \(codex.tokensToday.map(String.init) ?? "Unavailable")")
            if let spend = codex.dailySpend {
                print("Codex Cost Today      \(DailyAISpendSummary.usd(spend.cents)) \(spend.basis == .estimatedFromTokenBreakdown ? "estimated" : "reported")")
            }
            if let estimateNote = codex.notes.first(where: { $0.hasPrefix("Codex daily cost is an estimate") }) {
                print("Codex Cost Basis      \(estimateNote)")
            }
            print("Codex Threads         \(codex.threadCount == nil ? "Unavailable" : "Working")")
            for note in codex.notes {
                print("Codex Note            \(note)")
            }
        }

        if case .available(let claude) = report.claude {
            if let spend = claude.dailySpend {
                print("Claude Cost Today     ≈\(DailyAISpendSummary.usd(spend.cents)) API-price equivalent")
            } else {
                print("Claude Cost Today     Unavailable")
            }
            print("Claude Sessions       \(claude.sessionCount)")
            for note in claude.notes {
                print("Claude Note           \(note)")
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

    private static func gitRoot(at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--show-toplevel"]
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        let data: Data
        do {
            try process.run()
            data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
