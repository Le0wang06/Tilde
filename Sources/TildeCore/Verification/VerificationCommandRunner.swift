import Darwin
import Foundation

public struct VerificationRunResult: Sendable, Equatable {
    public let receipts: [CheckReceipt]
    public let outputExcerpt: String?

    public init(receipts: [CheckReceipt], outputExcerpt: String?) {
        self.receipts = receipts
        self.outputExcerpt = outputExcerpt
    }
}

public actor VerificationCommandRunner {
    private var currentPID: pid_t?
    private var currentFlags: ProcessTerminationFlags?
    private var isRunning = false
    private var cancellationRequested = false

    public init() {}

    public func run(
        checks: [VerificationCheck],
        in rootPath: String,
        onCheckStarted: (@Sendable (String) async -> Void)? = nil
    ) async throws -> VerificationRunResult {
        guard !isRunning else { throw VerificationError.runInProgress }
        isRunning = true
        defer {
            isRunning = false
            currentPID = nil
            currentFlags = nil
        }
        cancellationRequested = false
        var receipts: [CheckReceipt] = []
        let output = EphemeralOutputBuffer(limit: 32 * 1_024)

        for check in checks {
            if cancellationRequested { break }
            await onCheckStarted?(check.name)
            if cancellationRequested { break }
            receipts.append(try await runCheck(check, in: rootPath, output: output))
        }
        return VerificationRunResult(
            receipts: receipts,
            outputExcerpt: output.string.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    public func cancel() {
        cancellationRequested = true
        guard let currentPID, let currentFlags else { return }
        currentFlags.markCancelled()
        terminateProcessGroup(currentPID)
    }

    private func runCheck(
        _ check: VerificationCheck,
        in rootPath: String,
        output: EphemeralOutputBuffer
    ) async throws -> CheckReceipt {
        let startedAt = Date()
        let child = try spawn(command: check.command, rootPath: rootPath)
        let flags = ProcessTerminationFlags()
        currentPID = child.pid
        currentFlags = flags
        output.attach(to: child.stdout)
        output.attach(to: child.stderr)

        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(check.timeoutSeconds))
            guard !Task.isCancelled, !flags.finished else { return }
            flags.markTimedOut()
            terminateProcessGroup(child.pid)
        }
        let waitResult = await Task.detached(priority: .utility) {
            waitForChild(child.pid)
        }.value
        flags.markFinished()
        timeoutTask.cancel()
        await cleanUpProcessGroup(child.pid)
        output.detach(from: child.stdout)
        output.detach(from: child.stderr)
        currentPID = nil
        currentFlags = nil

        guard waitResult.errorNumber == 0 else {
            throw VerificationError.unableToLaunch(
                "Unable to wait for \(check.name): \(String(cString: strerror(waitResult.errorNumber)))"
            )
        }

        let finishedAt = Date()
        let outcome: CheckReceiptOutcome
        if flags.cancelled {
            outcome = .cancelled
        } else if flags.timedOut {
            outcome = .timedOut
        } else if waitResult.exitStatus == 0 {
            outcome = .passed
        } else {
            outcome = .failed
        }
        return CheckReceipt(
            checkID: check.id,
            checkName: check.name,
            commandHash: VerificationHash.sha256(check.command),
            required: check.required,
            startedAt: startedAt,
            finishedAt: finishedAt,
            duration: finishedAt.timeIntervalSince(startedAt),
            exitStatus: flags.timedOut || flags.cancelled ? nil : waitResult.exitStatus,
            outcome: outcome
        )
    }

    private func spawn(command: String, rootPath: String) throws -> SpawnedProcess {
        var stdoutFDs = [Int32](repeating: 0, count: 2)
        var stderrFDs = [Int32](repeating: 0, count: 2)
        guard Darwin.pipe(&stdoutFDs) == 0, Darwin.pipe(&stderrFDs) == 0 else {
            stdoutFDs.filter { $0 > 0 }.forEach { Darwin.close($0) }
            stderrFDs.filter { $0 > 0 }.forEach { Darwin.close($0) }
            throw VerificationError.unableToLaunch("Unable to create verification output pipes")
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            stdoutFDs.forEach { Darwin.close($0) }
            stderrFDs.forEach { Darwin.close($0) }
            throw VerificationError.unableToLaunch("Unable to initialize the verification process")
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        let setupResults = [
            posix_spawn_file_actions_adddup2(&actions, stdoutFDs[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, stderrFDs[1], STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, stdoutFDs[0]),
            posix_spawn_file_actions_addclose(&actions, stderrFDs[0]),
            posix_spawn_file_actions_addclose(&actions, stdoutFDs[1]),
            posix_spawn_file_actions_addclose(&actions, stderrFDs[1]),
            rootPath.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) },
            posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)),
        ]
        guard setupResults.allSatisfy({ $0 == 0 }) else {
            stdoutFDs.forEach { Darwin.close($0) }
            stderrFDs.forEach { Darwin.close($0) }
            throw VerificationError.unableToLaunch("Unable to configure the verification process group")
        }

        let arguments = ["/bin/zsh", "-c", command]
        let environment = ProcessInfo.processInfo.environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer {
            argv.compactMap { $0 }.forEach { free($0) }
            envp.compactMap { $0 }.forEach { free($0) }
        }

        var pid: pid_t = 0
        let spawnResult = argv.withUnsafeBufferPointer { argvBuffer in
            envp.withUnsafeBufferPointer { envBuffer in
                posix_spawn(
                    &pid,
                    "/bin/zsh",
                    &actions,
                    &attributes,
                    argvBuffer.baseAddress,
                    envBuffer.baseAddress
                )
            }
        }
        Darwin.close(stdoutFDs[1])
        Darwin.close(stderrFDs[1])
        guard spawnResult == 0 else {
            Darwin.close(stdoutFDs[0])
            Darwin.close(stderrFDs[0])
            throw VerificationError.unableToLaunch(
                "Unable to run verification command: \(String(cString: strerror(spawnResult)))"
            )
        }
        return SpawnedProcess(
            pid: pid,
            stdout: FileHandle(fileDescriptor: stdoutFDs[0], closeOnDealloc: true),
            stderr: FileHandle(fileDescriptor: stderrFDs[0], closeOnDealloc: true)
        )
    }
}

private struct SpawnedProcess: @unchecked Sendable {
    let pid: pid_t
    let stdout: FileHandle
    let stderr: FileHandle
}

private struct ChildWaitResult: Sendable {
    let exitStatus: Int32
    let errorNumber: Int32
}

private func waitForChild(_ pid: pid_t) -> ChildWaitResult {
    var rawStatus: Int32 = 0
    while true {
        let result = waitpid(pid, &rawStatus, 0)
        if result == pid {
            let signal = rawStatus & 0x7f
            let exitStatus = signal == 0 ? (rawStatus >> 8) & 0xff : 128 + signal
            return ChildWaitResult(exitStatus: exitStatus, errorNumber: 0)
        }
        if result == -1, errno == EINTR { continue }
        return ChildWaitResult(exitStatus: -1, errorNumber: errno)
    }
}

private func terminateProcessGroup(_ pid: pid_t) {
    _ = Darwin.kill(-pid, SIGTERM)
    Task.detached(priority: .utility) {
        try? await Task.sleep(for: .seconds(1))
        if processGroupExists(pid) {
            _ = Darwin.kill(-pid, SIGKILL)
        }
    }
}

private func cleanUpProcessGroup(_ pid: pid_t) async {
    guard processGroupExists(pid) else { return }
    _ = Darwin.kill(-pid, SIGTERM)
    for _ in 0..<20 {
        try? await Task.sleep(for: .milliseconds(50))
        if !processGroupExists(pid) { return }
    }
    _ = Darwin.kill(-pid, SIGKILL)
    for _ in 0..<20 {
        try? await Task.sleep(for: .milliseconds(25))
        if !processGroupExists(pid) { return }
    }
}

private func processGroupExists(_ pid: pid_t) -> Bool {
    Darwin.kill(-pid, 0) == 0 || errno == EPERM
}

private final class ProcessTerminationFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var didTimeOut = false
    private var wasCancelled = false
    private var didFinish = false

    var timedOut: Bool { lock.withLock { didTimeOut } }
    var cancelled: Bool { lock.withLock { wasCancelled } }
    var finished: Bool { lock.withLock { didFinish } }

    func markTimedOut() { lock.withLock { didTimeOut = true } }
    func markCancelled() { lock.withLock { wasCancelled = true } }
    func markFinished() { lock.withLock { didFinish = true } }
}

private final class EphemeralOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int) {
        self.limit = limit
    }

    var string: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }

    func attach(to handle: FileHandle) {
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.append(chunk)
        }
    }

    func detach(from handle: FileHandle) {
        handle.readabilityHandler = nil
        // A deliberately detached descendant can retain this pipe after the group leader exits.
        // Closing is bounded; a blocking drain would defeat the configured timeout.
        try? handle.close()
    }

    private func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > limit { data.removeFirst(data.count - limit) }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
