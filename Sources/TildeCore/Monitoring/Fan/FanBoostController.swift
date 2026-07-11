import Foundation

/// Coordinates fan boost for Tilde.
///
/// Reads SMC fan RPM in-process. Writes require root on Apple Silicon, so
/// when the toggle turns on we:
/// 1. try an in-process SMC write
/// 2. if permission is denied, start `tilde-fan hold` once with an admin prompt
///    (it re-applies the target every few seconds so thermalmonitord cannot reclaim)
/// 3. never downgrade a working boost to "failed" just because an unprivileged
///    keep-alive rewrite is denied
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
    private var privilegedHoldProcess: Process?
    private let boostFraction = 0.85

    public init() {}

    public func currentSnapshot(thermalState: TildeThermalState = .unavailable) -> Snapshot {
        let fans = (try? SMC().readFans()) ?? []
        let rpm = fans.map(\.actualRPM).max()
        let target = fans.map(\.targetRPM).max()
        let looksBoosted = fans.contains(where: isBoosted)

        // Hold process still running means boost is actively maintained.
        if enabled, privilegedHoldProcess?.isRunning == true, mode != .hardwareBoost {
            mode = .hardwareBoost
            lastError = nil
        }

        // Heal false "failed" when fans are clearly boosted.
        if enabled, looksBoosted, mode == .failed || mode == .needsPrivilege {
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
                detailText: "Admin approval required to control fans",
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
            stopPrivilegedHold()
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
                // If the privileged hold is already re-applying as root, leave it alone.
                if await self.privilegedHoldProcess?.isRunning == true { continue }
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
        } catch SMCError.permissionDenied {
            await handleWriteFailure(error: SMCError.permissionDenied, privilegedFallback: privilegedFallback)
        } catch {
            await handleWriteFailure(error: error, privilegedFallback: privilegedFallback)
        }
    }

    private func handleWriteFailure(error: Error, privilegedFallback: Bool) async {
        // Unprivileged keep-alive cannot rewrite SMC keys. If boost already
        // succeeded (or a privileged hold is running), keep showing success.
        if !privilegedFallback {
            if privilegedHoldProcess?.isRunning == true || mode == .hardwareBoost {
                return
            }
            mode = .needsPrivilege
            lastError = error.localizedDescription
            return
        }

        mode = .needsPrivilege
        do {
            try await startPrivilegedHold()
            mode = .hardwareBoost
            lastError = nil
        } catch {
            // One-shot boost as a last resort (still requires the same prompt).
            do {
                try await runPrivilegedFanCLI(argument: "boost", waitUntilExit: true)
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
        } catch SMCError.permissionDenied where privilegedFallback {
            try? await runPrivilegedFanCLI(argument: "auto", waitUntilExit: true)
        } catch {
            if privilegedFallback {
                try? await runPrivilegedFanCLI(argument: "auto", waitUntilExit: true)
            }
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

    private func startPrivilegedHold() async throws {
        if privilegedHoldProcess?.isRunning == true { return }

        stopPrivilegedHold()
        let helper = try resolveFanCLIURL()
        let escaped = helper.path.replacingOccurrences(of: "'", with: "'\\''")
        // One admin prompt; `hold` keeps re-applying boost until we terminate it.
        let script = "do shell script \"'\(escaped)' hold\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        privilegedHoldProcess = process

        // Password dialog can take a while. Fail only if the process exits.
        // Succeed early once fan targets look boosted.
        for _ in 0..<300 { // up to ~120s
            try await Task.sleep(for: .milliseconds(400))
            if !process.isRunning {
                let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                privilegedHoldProcess = nil
                throw FanCLIError.privilegedFailed(message ?? "Admin authorization failed")
            }
            if let fans = try? SMC().readFans(), fans.contains(where: isBoosted(_:)) {
                return
            }
        }

        // Still alive after the wait window — treat hold as active.
        if process.isRunning { return }
        privilegedHoldProcess = nil
        throw FanCLIError.privilegedFailed("Admin authorization failed")
    }

    private func isBoosted(_ fan: FanInfo) -> Bool {
        let floor = max(fan.minRPM + 200, Int(Double(fan.maxRPM) * 0.55))
        return fan.targetRPM >= floor || fan.actualRPM >= floor
    }

    private func stopPrivilegedHold() {
        guard let process = privilegedHoldProcess else { return }
        process.terminate()
        process.waitUntilExit()
        privilegedHoldProcess = nil
    }

    private func runPrivilegedFanCLI(argument: String, waitUntilExit: Bool) async throws {
        let helper = try resolveFanCLIURL()
        let escaped = helper.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = "do shell script \"'\(escaped)' \(argument)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        if waitUntilExit {
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw FanCLIError.privilegedFailed(message ?? "Admin authorization failed")
            }
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
