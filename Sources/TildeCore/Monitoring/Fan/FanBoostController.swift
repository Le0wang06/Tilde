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
        case starting
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
        /// 0.15…1.0 of the fan's available range (min→max).
        public var speed: Double

        /// True only when fans are confirmed boosted — use for green UI / tilde spray.
        public var isActivelyBoosting: Bool { mode == .hardwareBoost }

        /// True while waiting on admin, daemon, or fan spin-up.
        public var isPending: Bool {
            mode == .starting || mode == .needsPrivilege
        }

        public var speedPercent: Int { Int((speed * 100).rounded()) }

        public init(
            isEnabled: Bool,
            mode: Mode,
            statusText: String,
            detailText: String,
            rpm: Int? = nil,
            speed: Double = 0.7
        ) {
            self.isEnabled = isEnabled
            self.mode = mode
            self.statusText = statusText
            self.detailText = detailText
            self.rpm = rpm
            self.speed = min(max(speed, 0.15), 1.0)
        }

        public static let idle = Snapshot(
            isEnabled: false,
            mode: .off,
            statusText: "Off",
            detailText: "Tap to boost cooling",
            rpm: 0,
            speed: 0.7
        )
    }

    private var enabled = false
    private var mode: Mode = .off
    private var lastError: String?
    private var keepAliveTask: Task<Void, Never>?
    private var daemonStartProcess: Process?
    private var boostFraction = 0.7
    /// Once the privileged daemon has answered, never show another password prompt
    /// for boost/speed/off — only talk to the socket.
    private var daemonReady = false

    public init() {}

    public func currentSnapshot(thermalState: TildeThermalState = .unavailable) -> Snapshot {
        let fans = (try? SMC().readFans()) ?? []
        let rpm = fans.map(\.actualRPM).max()
        let target = fans.map(\.targetRPM).max()
        let looksBoosted = fans.contains(where: isBoosted)

        // Promote starting → on only once fans (or target) actually show boost.
        if enabled, looksBoosted, mode == .starting || mode == .needsPrivilege {
            mode = .hardwareBoost
            lastError = nil
        }

        if !enabled {
            return Snapshot(
                isEnabled: false,
                mode: .off,
                statusText: "Off",
                detailText: "Drag the bar, then turn on",
                rpm: 0,
                speed: boostFraction
            )
        }

        switch mode {
        case .starting:
            return Snapshot(
                isEnabled: true,
                mode: .starting,
                statusText: "Starting…",
                detailText: "0 RPM · spinning fans up to \(Int((boostFraction * 100).rounded()))%",
                rpm: 0,
                speed: boostFraction
            )
        case .hardwareBoost:
            let detail: String
            if let rpm, rpm > 0 {
                detail = "\(rpm) RPM · \(Int((boostFraction * 100).rounded()))% target"
            } else if let target, target > 0 {
                detail = "Target \(target) RPM · \(Int((boostFraction * 100).rounded()))%"
            } else {
                detail = "Fans at \(Int((boostFraction * 100).rounded()))%"
            }
            return Snapshot(
                isEnabled: true,
                mode: .hardwareBoost,
                statusText: "Boost On",
                detailText: detail,
                rpm: rpm,
                speed: boostFraction
            )
        case .needsPrivilege:
            return Snapshot(
                isEnabled: true,
                mode: .needsPrivilege,
                statusText: "Waiting for access",
                detailText: "Approve admin once — then toggles stay unlocked",
                rpm: 0,
                speed: boostFraction
            )
        case .failed:
            return Snapshot(
                isEnabled: true,
                mode: .failed,
                statusText: "Boost failed",
                detailText: lastError ?? "Could not control fans on this Mac",
                rpm: rpm ?? 0,
                speed: boostFraction
            )
        case .off:
            return Snapshot(
                isEnabled: false,
                mode: .off,
                statusText: "Off",
                detailText: "Drag the bar, then turn on",
                rpm: 0,
                speed: boostFraction
            )
        }
    }

    public func setEnabled(_ on: Bool, thermalState: TildeThermalState) async -> Snapshot {
        if on {
            enabled = true
            mode = .starting
            lastError = nil
            // Reuse an already-running daemon from an earlier unlock this login.
            if FanDaemonClient.isAvailable() {
                daemonReady = true
            }
            await applyBoost(allowPasswordPrompt: !daemonReady)
            if mode != .failed && mode != .needsPrivilege {
                await waitUntilBoostedOrTimeout()
            }
            if mode != .failed {
                startKeepAlive()
            }
        } else {
            keepAliveTask?.cancel()
            keepAliveTask = nil
            await forceReleaseFans()
            enabled = false
            mode = .off
            lastError = nil
        }
        return currentSnapshot(thermalState: thermalState)
    }

    /// Best-effort: stop holding and return fans to system auto (no password).
    public func forceReleaseFans() async {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        enabled = false
        mode = .off
        lastError = nil
        await restoreAuto(allowPasswordPrompt: false)
        // Extra daemon kicks in case a stale hold left targets high.
        if FanDaemonClient.isAvailable() {
            _ = try? FanDaemonClient.send(FanDaemonProtocol.auto)
            try? await Task.sleep(for: .milliseconds(200))
            _ = try? FanDaemonClient.send(FanDaemonProtocol.auto)
            daemonReady = true
        }
    }

    public func setSpeed(_ speed: Double, thermalState: TildeThermalState) async -> Snapshot {
        boostFraction = min(max(speed, 0.15), 1.0)
        guard enabled else {
            return currentSnapshot(thermalState: thermalState)
        }
        // Speed changes must never re-prompt. Use the cached daemon only.
        if mode == .hardwareBoost || mode == .starting {
            await applyBoost(allowPasswordPrompt: false)
        }
        return currentSnapshot(thermalState: thermalState)
    }

    /// Don't claim "Boost On" until fans/target look boosted (or a short timeout if RPM stays 0).
    private func waitUntilBoostedOrTimeout() async {
        for _ in 0..<40 {
            if !enabled { return }
            if mode == .failed { return }
            let fans = (try? SMC().readFans()) ?? []
            if fans.contains(where: isBoosted) {
                mode = .hardwareBoost
                lastError = nil
                return
            }
            mode = mode == .needsPrivilege ? .needsPrivilege : .starting
            try? await Task.sleep(for: .milliseconds(250))
        }
        // Apple Silicon sometimes reports 0 actual RPM; if the command armed successfully,
        // promote after the wait so we don't stay on Starting forever.
        if mode == .starting {
            mode = .hardwareBoost
        }
    }

    private func startKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard let self, await self.enabled else { break }
                if await self.daemonReady || FanDaemonClient.isAvailable() {
                    _ = try? FanDaemonClient.send(
                        FanDaemonProtocol.boostCommand(fraction: await self.boostFraction)
                    )
                    continue
                }
                await self.applyBoost(allowPasswordPrompt: false)
            }
        }
    }

    private func applyBoost(allowPasswordPrompt: Bool) async {
        do {
            try boostInProcess()
            if mode != .hardwareBoost { mode = .starting }
            lastError = nil
            return
        } catch {
            await handleWriteFailure(allowPasswordPrompt: allowPasswordPrompt)
        }
    }

    private func handleWriteFailure(allowPasswordPrompt: Bool) async {
        // 1) Always try the existing daemon first — no password.
        if daemonReady || FanDaemonClient.isAvailable() {
            if await sendBoostToDaemon(retries: 3) {
                daemonReady = true
                if mode != .hardwareBoost { mode = .starting }
                lastError = nil
                return
            }
            // Live socket but commands failing (e.g. stale daemon binary).
            // Only re-prompt when explicitly allowed (first turn-on), never on slider.
            if !allowPasswordPrompt {
                mode = .failed
                lastError = "Fan daemon not responding — toggle off/on once"
                daemonReady = false
                return
            }
            daemonReady = false
        }

        guard allowPasswordPrompt else {
            if mode == .hardwareBoost || mode == .starting { return }
            mode = .needsPrivilege
            lastError = "Admin approval required once to control fans"
            return
        }

        // 2) One-time password: (re)start daemon, then only use the socket afterward.
        mode = .needsPrivilege
        do {
            try await ensurePrivilegedDaemon(forceRestart: FanDaemonClient.isAvailable())
            guard await sendBoostToDaemon(retries: 5) else {
                throw FanCLIError.privilegedFailed("Fan daemon started but did not accept boost")
            }
            daemonReady = true
            mode = .starting
            lastError = nil
        } catch {
            mode = .failed
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    private func sendBoostToDaemon(retries: Int) async -> Bool {
        let commands = [
            FanDaemonProtocol.boostCommand(fraction: boostFraction),
            FanDaemonProtocol.boost, // back-compat with older daemons
        ]
        for attempt in 0..<retries {
            for command in commands {
                do {
                    try FanDaemonClient.send(command)
                    return true
                } catch {
                    continue
                }
            }
            if attempt + 1 < retries {
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        return false
    }

    private func restoreAuto(allowPasswordPrompt: Bool) async {
        do {
            try restoreInProcess()
            return
        } catch {
            // Continue via daemon.
        }

        if daemonReady || FanDaemonClient.isAvailable() {
            for _ in 0..<3 {
                if (try? FanDaemonClient.send(FanDaemonProtocol.auto)) != nil { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return
        }

        guard allowPasswordPrompt else { return }
        do {
            try await ensurePrivilegedDaemon()
            _ = try? FanDaemonClient.send(FanDaemonProtocol.auto)
            daemonReady = true
        } catch {
            // Don't launch password-hold fallback — that re-prompts every time.
        }
    }

    private func boostInProcess() throws {
        let smc = try SMC()
        let fans = try smc.readFans()
        guard !fans.isEmpty else {
            throw SMCError.serviceNotFound("fan keys")
        }
        for fan in fans {
            let target = FanDaemonServer.targetRPM(for: fan, fraction: boostFraction)
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
    private func ensurePrivilegedDaemon(forceRestart: Bool = false) async throws {
        if !forceRestart, FanDaemonClient.isAvailable() {
            // Stale daemons accept bare `boost` but reject `boost 0.70` — detect and replace.
            do {
                try FanDaemonClient.send(FanDaemonProtocol.boostCommand(fraction: boostFraction))
                daemonReady = true
                return
            } catch {
                // Fall through and replace the outdated daemon (one password).
            }
        }

        let helper = try resolveFanCLIURL()
        let socketURL = FanDaemonProtocol.socketURL()
        let socketPath = socketURL.path

        // Ask any existing daemon to exit cleanly, then clear a dead socket.
        if FanDaemonClient.isAvailable(socketPath: socketPath) {
            _ = try? FanDaemonClient.send(FanDaemonProtocol.quit)
            try? await Task.sleep(for: .milliseconds(250))
        }
        if FileManager.default.fileExists(atPath: socketPath) {
            try? FileManager.default.removeItem(at: socketURL)
        }

        let escapedHelper = helper.path.replacingOccurrences(of: "'", with: "'\\''")
        let escapedSocket = socketPath.replacingOccurrences(of: "'", with: "'\\''")
        let uid = getuid()
        let logPath = "/tmp/tilde-fan-daemon-\(uid).log"
        // Important: do NOT use `nohup` here — under `do shell script` it fails with
        // "can't detach from console" and the daemon never starts. Background with `&`
        // inside a subshell so AppleScript can return while the daemon keeps running.
        let script =
            "do shell script \"( pkill -f 'tilde-fan hold' || true; " +
            "pkill -f 'tilde-fan daemon' || true; " +
            "'\(escapedHelper)' daemon --socket '\(escapedSocket)' --uid \(uid) " +
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
                daemonReady = true
                return
            }
        }
        let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        throw FanCLIError.privilegedFailed(
            log.isEmpty ? "Fan daemon failed to start" : log.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func isBoosted(_ fan: FanInfo) -> Bool {
        let wanted = FanDaemonServer.targetRPM(for: fan, fraction: boostFraction)
        let floor = max(fan.minRPM, Int(Double(wanted) * 0.8))
        return fan.targetRPM >= floor || fan.actualRPM >= floor
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
