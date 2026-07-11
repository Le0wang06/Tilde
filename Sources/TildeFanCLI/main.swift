import Foundation
import TildeCore

@main
enum TildeFanCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "status"
        do {
            let smc = try SMC()
            switch command {
            case "status":
                let fans = try smc.readFans()
                if fans.isEmpty {
                    print("no-fans")
                    exit(1)
                }
                for fan in fans {
                    print("fan\(fan.index) actual=\(fan.actualRPM) min=\(fan.minRPM) max=\(fan.maxRPM) target=\(fan.targetRPM)")
                }
            case "boost":
                let fans = try smc.readFans()
                guard !fans.isEmpty else {
                    fputs("No fans found\n", stderr)
                    exit(2)
                }
                for fan in fans {
                    let target = max(fan.minRPM, Int(Double(fan.maxRPM) * 0.85))
                    try smc.setFanTarget(index: fan.index, rpm: target)
                    print("fan\(fan.index) -> \(target)")
                }
            case "auto":
                let fans = try smc.readFans()
                for fan in fans {
                    try smc.restoreFanAuto(index: fan.index)
                    print("fan\(fan.index) -> auto")
                }
                try? smc.resetFanTestUnlock()
            default:
                fputs("Usage: tilde-fan status|boost|auto\n", stderr)
                exit(64)
            }
        } catch {
            fputs("\(error)\n", stderr)
            exit(error is SMCError ? 3 : 2)
        }
    }
}
