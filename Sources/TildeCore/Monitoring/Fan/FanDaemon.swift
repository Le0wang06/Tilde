import Darwin
import Foundation

/// Shared Unix-socket protocol for the privileged `tilde-fan daemon`.
///
/// After one admin prompt starts the daemon, the app can send `boost` / `auto`
/// without asking for the password again (until reboot or the daemon exits).
public enum FanDaemonProtocol {
    public static let boost = "boost"
    public static let auto = "auto"
    public static let ping = "ping"
    public static let quit = "quit"

    /// Prefer `/tmp` so the path has no spaces (safer inside AppleScript shell).
    public static func socketURL(uid: uid_t = getuid()) -> URL {
        URL(fileURLWithPath: "/tmp/tilde-fan-\(uid).sock")
    }

    public static func boostCommand(fraction: Double) -> String {
        let clamped = min(max(fraction, 0.15), 1.0)
        return "\(boost) \(String(format: "%.3f", clamped))"
    }
}

public enum FanDaemonClient {
    public static func isAvailable(socketPath: String? = nil) -> Bool {
        let path = socketPath ?? FanDaemonProtocol.socketURL().path
        return (try? send(FanDaemonProtocol.ping, socketPath: path)) == "ok"
    }

    @discardableResult
    public static func send(_ command: String, socketPath: String? = nil, timeoutSeconds: Double = 3) throws -> String {
        let path = socketPath ?? FanDaemonProtocol.socketURL().path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FanDaemonError.socketFailed("socket()") }

        defer { close(fd) }

        var timeout = timeval(
            tv_sec: Int(timeoutSeconds),
            tv_usec: Int32((timeoutSeconds - floor(timeoutSeconds)) * 1_000_000)
        )
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= maxPath else { throw FanDaemonError.socketFailed("path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = UInt8(bitPattern: byte)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { throw FanDaemonError.notRunning }

        let payload = command + "\n"
        let written = payload.withCString { cstr in
            Darwin.write(fd, cstr, strlen(cstr))
        }
        guard written > 0 else { throw FanDaemonError.socketFailed("write failed") }

        var buffer = [UInt8](repeating: 0, count: 1024)
        let readCount = Darwin.read(fd, &buffer, buffer.count - 1)
        guard readCount > 0 else { throw FanDaemonError.socketFailed("no response") }
        let response = String(bytes: buffer.prefix(readCount), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if response == "ok" || response.hasPrefix("ok") {
            return "ok"
        }
        if response.hasPrefix("error:") {
            throw FanDaemonError.commandFailed(String(response.dropFirst(6)).trimmingCharacters(in: .whitespaces))
        }
        throw FanDaemonError.commandFailed(response.isEmpty ? "empty response" : response)
    }
}

public enum FanDaemonError: Error, LocalizedError {
    case notRunning
    case socketFailed(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Fan daemon is not running"
        case .socketFailed(let message):
            return "Fan daemon socket error: \(message)"
        case .commandFailed(let message):
            return message
        }
    }
}

/// Root-side Unix socket server used by `tilde-fan daemon`.
public final class FanDaemonServer: @unchecked Sendable {
    private let socketPath: String
    private let ownerUID: uid_t
    private let lock = NSLock()
    private var boostFraction: Double
    private var holding = false
    private var shouldStop = false
    private var holdThread: Thread?

    public init(socketPath: String, ownerUID: uid_t, boostFraction: Double = 0.7) {
        self.socketPath = socketPath
        self.ownerUID = ownerUID
        self.boostFraction = boostFraction
    }

    public func run() throws {
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FanDaemonError.socketFailed("socket()") }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxPath else { throw FanDaemonError.socketFailed("path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = UInt8(bitPattern: byte)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw FanDaemonError.socketFailed("bind failed (\(errno))")
        }
        guard listen(fd, 8) == 0 else { throw FanDaemonError.socketFailed("listen failed") }

        chmod(socketPath, 0o600)
        if let password = getpwuid(ownerUID) {
            chown(socketPath, ownerUID, password.pointee.pw_gid)
        } else {
            chown(socketPath, ownerUID, 0)
        }

        startHoldLoop()
        fputs("tilde-fan daemon ready at \(socketPath)\n", stderr)

        while !shouldStop {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            handleClient(client)
            close(client)
        }

        lock.lock()
        holding = false
        lock.unlock()
        unlink(socketPath)
    }

    private func startHoldLoop() {
        let thread = Thread { [weak self] in
            while let self, !self.shouldStop {
                self.lock.lock()
                let active = self.holding
                self.lock.unlock()
                if active {
                    try? self.applyBoost()
                }
                Thread.sleep(forTimeInterval: 8)
            }
        }
        thread.name = "tilde-fan-hold"
        thread.start()
        holdThread = thread
    }

    private func handleClient(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = Darwin.read(fd, &buffer, buffer.count - 1)
        guard count > 0,
              let line = String(bytes: buffer.prefix(count), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty
        else {
            _ = writeResponse(fd, "error: empty")
            return
        }

        do {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            let command = String(parts[0])
            switch command {
            case FanDaemonProtocol.ping:
                _ = writeResponse(fd, "ok")
            case FanDaemonProtocol.boost:
                if parts.count > 1, let value = Double(parts[1]) {
                    lock.lock()
                    boostFraction = min(max(value, 0.15), 1.0)
                    lock.unlock()
                }
                lock.lock(); holding = true; lock.unlock()
                try applyBoost()
                _ = writeResponse(fd, "ok")
            case FanDaemonProtocol.auto:
                lock.lock(); holding = false; lock.unlock()
                try applyAuto()
                _ = writeResponse(fd, "ok")
            case FanDaemonProtocol.quit:
                lock.lock(); holding = false; lock.unlock()
                try? applyAuto()
                _ = writeResponse(fd, "ok")
                shouldStop = true
            default:
                _ = writeResponse(fd, "error: unknown command")
            }
        } catch {
            _ = writeResponse(fd, "error: \(error.localizedDescription)")
        }
    }

    private func writeResponse(_ fd: Int32, _ message: String) -> Bool {
        let payload = message + "\n"
        return payload.withCString { cstr in
            Darwin.write(fd, cstr, strlen(cstr)) > 0
        }
    }

    private func applyBoost() throws {
        lock.lock()
        let fraction = boostFraction
        lock.unlock()
        let smc = try SMC()
        let fans = try smc.readFans()
        guard !fans.isEmpty else { throw SMCError.serviceNotFound("fan keys") }
        for fan in fans {
            let target = Self.targetRPM(for: fan, fraction: fraction)
            try smc.setFanTarget(index: fan.index, rpm: target)
        }
    }

    private func applyAuto() throws {
        let smc = try SMC()
        let fans = try smc.readFans()
        for fan in fans {
            try smc.restoreFanAuto(index: fan.index)
        }
        try? smc.resetFanTestUnlock()
    }

    public static func targetRPM(for fan: FanInfo, fraction: Double) -> Int {
        let clamped = min(max(fraction, 0.15), 1.0)
        let span = max(0, fan.maxRPM - fan.minRPM)
        return fan.minRPM + Int(Double(span) * clamped)
    }
}
