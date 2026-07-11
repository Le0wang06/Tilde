import Foundation
import TildeCore

@main
enum TildeFanCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "status"
        do {
            switch command {
            case "status":
                try runStatus()
            case "boost":
                try runBoost()
            case "hold":
                try runHold()
            case "auto":
                try runAuto()
            case "daemon":
                try runDaemon(args: Array(args.dropFirst()))
            default:
                fputs("Usage: tilde-fan status|boost|hold|auto|daemon\n", stderr)
                exit(64)
            }
        } catch {
            fputs("\(error)\n", stderr)
            exit(error is SMCError ? 3 : 2)
        }
    }

    private static func runStatus() throws {
        let smc = try SMC()
        let fans = try smc.readFans()
        if fans.isEmpty {
            print("no-fans")
            exit(1)
        }
        for fan in fans {
            print("fan\(fan.index) actual=\(fan.actualRPM) min=\(fan.minRPM) max=\(fan.maxRPM) target=\(fan.targetRPM)")
        }
    }

    private static func runBoost() throws {
        let smc = try SMC()
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
    }

    /// Keep re-applying boost until SIGTERM/SIGINT (legacy one-shot hold).
    private static func runHold() throws {
        signal(SIGTERM, SIG_DFL)
        signal(SIGINT, SIG_DFL)

        var shouldStop = false
        let sources = [
            DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global()),
            DispatchSource.makeSignalSource(signal: SIGINT, queue: .global()),
        ]
        for source in sources {
            source.setEventHandler { shouldStop = true }
            source.resume()
        }
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        while !shouldStop {
            try runBoost()
            for _ in 0..<16 {
                if shouldStop { break }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    private static func runAuto() throws {
        let smc = try SMC()
        let fans = try smc.readFans()
        for fan in fans {
            try smc.restoreFanAuto(index: fan.index)
            print("fan\(fan.index) -> auto")
        }
        try? smc.resetFanTestUnlock()
    }

    /// Privileged long-lived control plane. Password once; then app sends boost/auto on the socket.
    private static func runDaemon(args: [String]) throws {
        var socketPath: String?
        var ownerUID = getuid()
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--socket", index + 1 < args.count {
                socketPath = args[index + 1]
                index += 2
            } else if arg == "--uid", index + 1 < args.count {
                ownerUID = uid_t(UInt32(args[index + 1]) ?? UInt32(getuid()))
                index += 2
            } else {
                index += 1
            }
        }

        let path = socketPath ?? FanDaemonProtocol.socketURL(uid: ownerUID).path
        let server = FanDaemonServer(socketPath: path, ownerUID: ownerUID)
        try server.run()
    }
}
