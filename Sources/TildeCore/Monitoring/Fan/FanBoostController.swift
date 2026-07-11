import Foundation

/// Coordinates fan boost for Tilde.
///
/// Reads SMC fan RPM in-process. Writes require root on Apple Silicon, so
/// when the toggle turns on we:
/// 1. try an in-process SMC write
/// 2. if permission is denied, re-run `tilde-fan boost` with an admin prompt
/// 3. keep re-applying the target while boost stays enabled (thermalmonitord
///    otherwise reclaims control)
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
    private let boostFraction = 0.85

    public init() {}

    public func currentSnapshot(thermalState: TildeThermalState = .unavailable) -> Snapshot {
        let rpm = (try? readPrimaryRPM()) ?? nil
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
            return Snapshot(
                isEnabled: true,
                mode: .hardwareBoost,
                statusText: "Boost On",
                detailText: rpm.map { "\($0) RPM · system fans spinning" } ?? "Fans boosted",
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
            mode = .needsPrivilege
            guard privilegedFallback else { return }
            do {
                try await runPrivilegedFanCLI(argument: "boost")
                mode = .hardwareBoost
                lastError = nil
            } catch {
                mode = .failed
                lastError = error.localizedDescription
            }
        } catch {
            if privilegedFallback {
                do {
                    try await runPrivilegedFanCLI(argument: "boost")
                    mode = .hardwareBoost
                    lastError = nil
                    return
                } catch {
                    mode = .failed
                    lastError = error.localizedDescription
                }
            } else {
                mode = .failed
                lastError = error.localizedDescription
            }
        }
    }

    private func restoreAuto(privilegedFallback: Bool) async {
        do {
            try restoreInProcess()
        } catch SMCError.permissionDenied where privilegedFallback {
            try? await runPrivilegedFanCLI(argument: "auto")
        } catch {
            if privilegedFallback {
                try? await runPrivilegedFanCLI(argument: "auto")
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

    private func readPrimaryRPM() throws -> Int? {
        let smc = try SMC()
        let fans = try smc.readFans()
        return fans.first?.actualRPM
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
        // swift run puts products in .build/.../debug/
        let buildSibling = executable
            .deletingLastPathComponent()
            .appendingPathComponent("tilde-fan")
        if FileManager.default.isExecutableFile(atPath: buildSibling.path) {
            return buildSibling
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
