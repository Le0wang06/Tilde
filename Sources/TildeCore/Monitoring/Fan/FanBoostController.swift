import Darwin
import Foundation

/// Coordinates fan boost for Tilde.
///
/// Reads SMC fan RPM in-process. Writes require root on Apple Silicon, so
/// when the toggle turns on we:
/// 1. try an in-process SMC write
/// 2. if that fails, talk to a privileged `tilde-fan daemon` over a local socket
/// 3. if the daemon is not running yet, start it once with an admin password prompt
///    and keep it alive so later toggles do not ask again
///
/// SMC client code is adapted from [macfanctl](https://github.com/2dubu/macfanctl) (MIT).
public actor FanBoostController {
    public enum Mode: String, Sendable, Equatable {
        case off
        case hardwareBoost
        case needsPrivilege
        case failed
    }

    public struct Snapshot: Sendable, Equatable {
        public var isEnabled: Bool
        public var mode: Mode
        public var statusText: String
        public var detailText: String
        public var rpm: Int?

        public init(
            isEnabled: Bool,
            mode: Mode,
            statusText: String,
            detailText: String,
            rpm: Int? = nil
        ) {
            self.isEnabled = isEnabled
            self.mode = mode
            self.statusText = statusText
            self.detailText = detailText
            self.rpm = rpm
        }

        public static let idle = Snapshot(
            isEnabled: false,
            mode: .off,
            statusText: "Off",
            detailText: "Tap to boost cooling",
            rpm: nil
        )
    }

    private var enabled = false
    private var mode: Mode = .off
    private var lastError: String?
    private var keepAliveTask: Task<Void, Never>?
    private var daemonStartProcess: Process?
    private let boostFraction = 0.85

    public init() {}

    public func currentSnapshot(thermalState: TildeThermalState = .unavailable) -> Snapshot {
        let fans = (try? SMC().readFans()) ?? []
        let rpm = fans.map(\.actualRPM).max()
        let target = fans.map(\.targetRPM).max()
        let looksBoosted = fans.contains(where: isBoosted)
        let daemonUp = FanDaemonClient.isAvailable()

        if enabled, daemonUp || looksBoosted, mode == .failed || mode == .needsPrivilege {
            mode = .hardwareBoost
            lastError = nil
        }

        if !enabled {
            return Snapshot(
                isEnabled: false,
                mode: .off,
                statusText: "Off",
                detailText: "Tap to boost cooling",
                rpm: rpm
            )
        }

        switch mode {
        case .hardwareBoost:
            let detail: String
            if let rpm, rpm > 0 {
                detail = "\(rpm) RPM · system fans spinning"
            } else if let target, target > 0 {
                detail = "Target \(target) RPM · boost held"
            } else {
                detail = "Fans boosted"
            }
            return Snapshot(
                isEnabled: true,
                mode: .hardwareBoost,
                statusText: "Boost On",
                detailText: detail,
                rpm: rpm
            )
        case .needsPrivilege:
            return Snapshot(
                isEnabled: true,
                mode: .needsPrivilege,
                statusText: "Waiting for access",
                detailText: "Admin approval required once to control fans",
                rpm: rpm
            )
        case .failed:
            return Snapshot(
                isEnabled: true,
                mode: .failed,
                statusText: "Boost failed",
                detailText: lastError ?? "Could not control fans on this Mac",
                rpm: rpm
            )
        case .off:
            return .idle
        }
    }

    public func setEnabled(_ on: Bool, thermalState: TildeThermalState) async -> Snapshot {
        if on {
            enabled = true
            await applyBoost(privilegedFallback: true)
            startKeepAlive()
        } else {
            keepAliveTask?.cancel()
            keepAliveTask = nil
            await restoreAuto(privilegedFallback: true)
            enabled = false
            mode = .off
            lastError = nil
        }
        return currentSnapshot(thermalState: thermalState)
    }

    private func startKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard let self, await self.enabled else { break }
                // Privileged daemon already re-applies while holding.
                if FanDaemonClient.isAvailable() { continue }
                await self.applyBoost(privilegedFallback: false)
            }
        }
    }

    private func applyBoost(privilegedFallback: Bool) async {
        do {
            try boostInProcess()
            mode = .hardwareBoost
            lastError = nil
            return
        } catch {
            await handleWriteFailure(error: error, privilegedFallback: privilegedFallback)
        }
    }

    private func handleWriteFailure(error: Error, privilegedFallback: Bool) async {
        // Prefer the cached privileged daemon — no password if it's already up.
        if FanDaemonClient.isAvailable() {
            do {
                try FanDaemonClient.send(FanDaemonProtocol.boost)
                mode = .hardwareBoost
                lastError = nil
                return
            } catch {
                // Fall through and try (re)starting if allowed.
                if !privilegedFallback {
                    if mode == .hardwareBoost { return }
                    mode = .needsPrivilege
                    lastError = error.localizedDescription
                    return
                }
            }
        } else if !privilegedFallback {
            if mode == .hardwareBoost { return }
            mode = .needsPrivilege
            lastError = error.localizedDescription
            return
        }

        mode = .needsPrivilege
        do {
            try await ensurePrivilegedDaemon()
            try FanDaemonClient.send(FanDaemonProtocol.boost)
            mode = .hardwareBoost
            lastError = nil
        } catch {
            // Fall back to a one-shot privileged hold if the daemon failed to detach.
            do {
                try await startPrivilegedHoldFallback()
                mode = .hardwareBoost
                lastError = nil
            } catch {
                mode = .failed
                lastError = error.localizedDescription
            }
        }
    }

    private func restoreAuto(privilegedFallback: Bool) async {
        do {
            try restoreInProcess()
            return
        } catch {
            // Keep going — restore via daemon when possible.
        }

        if FanDaemonClient.isAvailable() {
            _ = try? FanDaemonClient.send(FanDaemonProtocol.auto)
            return
        }

        guard privilegedFallback else { return }
        do {
            try await ensurePrivilegedDaemon()
            try FanDaemonClient.send(FanDaemonProtocol.auto)
        } catch {
            try? await runPrivilegedFanCLI(argument: "auto")
        }
    }

    private func boostInProcess() throws {
        let smc = try SMC()
        let fans = try smc.readFans()
        guard !fans.isEmpty else {
            throw SMCError.serviceNotFound("fan keys")
        }
        for fan in fans {
            let target = max(fan.minRPM, Int(Double(fan.maxRPM) * boostFraction))
            try smc.setFanTarget(index: fan.index, rpm: target)
        }
    }

    private func restoreInProcess() throws {
        let smc = try SMC()
        let fans = try smc.readFans()
        for fan in fans {
            try smc.restoreFanAuto(index: fan.index)
        }
        try? smc.resetFanTestUnlock()
    }

    /// Start the root daemon once (admin password). Stays up so later toggles are free.
    private func ensurePrivilegedDaemon() async throws {
        if FanDaemonClient.isAvailable() { return }

        let helper = try resolveFanCLIURL()
        let socketURL = FanDaemonProtocol.socketURL()
        let socketPath = socketURL.path
        try? FileManager.default.removeItem(at: socketURL)

        let escapedHelper = helper.path.replacingOccurrences(of: "'", with: "'\\''")
        let escapedSocket = socketPath.replacingOccurrences(of: "'", with: "'\\''")
        let uid = getuid()
        let logPath = "/tmp/tilde-fan-daemon-\(uid).log"
        // Important: do NOT use `nohup` here — under `do shell script` it fails with
        // "can't detach from console" and the daemon never starts. Background with `&`
        // inside a subshell so AppleScript can return while the daemon keeps running.
        let script =
            "do shell script \"( '\(escapedHelper)' daemon --socket '\(escapedSocket)' --uid \(uid) " +
            ">>'\(logPath)' 2>&1 & )\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        daemonStartProcess = process

        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw FanCLIError.privilegedFailed(message ?? "Admin authorization failed")
        }

        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(100))
            if FanDaemonClient.isAvailable(socketPath: socketPath) {
                return
            }
        }
        let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        throw FanCLIError.privilegedFailed(
            log.isEmpty ? "Fan daemon failed to start" : log.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Legacy fallback: keep a privileged `hold` process alive for this boost session.
    private func startPrivilegedHoldFallback() async throws {
        let helper = try resolveFanCLIURL()
        let escaped = helper.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = "do shell script \"'\(escaped)' hold\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        daemonStartProcess = process

        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(200))
            if !process.isRunning {
                let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw FanCLIError.privilegedFailed(message ?? "Admin authorization failed")
            }
            if let fans = try? SMC().readFans(), fans.contains(where: isBoosted) {
                return
            }
        }
        if process.isRunning { return }
        throw FanCLIError.privilegedFailed("Admin authorization failed")
    }

    private func isBoosted(_ fan: FanInfo) -> Bool {
        let floor = max(fan.minRPM + 200, Int(Double(fan.maxRPM) * 0.55))
        return fan.targetRPM >= floor || fan.actualRPM >= floor
    }

    private func runPrivilegedFanCLI(argument: String) async throws {
        let helper = try resolveFanCLIURL()
        let escaped = helper.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = "do shell script \"'\(escaped)' \(argument)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw FanCLIError.privilegedFailed(message ?? "Admin authorization failed")
        }
    }

    private func resolveFanCLIURL() throws -> URL {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let sibling = executable.deletingLastPathComponent().appendingPathComponent("tilde-fan")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        throw FanCLIError.helperMissing
    }
}

private enum FanCLIError: Error, LocalizedError {
    case helperMissing
    case privilegedFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "Missing tilde-fan helper next to the app binary"
        case .privilegedFailed(let message):
            return message
        }
    }
}
