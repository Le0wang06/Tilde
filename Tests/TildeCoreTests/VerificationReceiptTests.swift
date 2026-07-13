import Foundation
import Testing
@testable import TildeCore

@Test func profileLoaderNormalizesDefaultsAndRejectsUnsafeShape() throws {
    let root = try makeVerificationRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    let profileURL = root.appendingPathComponent(".tilde/verify.json")
    let profileText = """
    {
      "version": 1,
      "base": "main",
      "checks": [
        {"id": "tests", "name": "Tests", "command": "true"}
      ]
    }
    """
    try profileText.write(to: profileURL, atomically: true, encoding: .utf8)

    let maybeLoaded = try VerificationProfileLoader().load(from: root.path)
    let loaded = try #require(maybeLoaded)
    #expect(loaded.profile.checks[0].required)
    #expect(loaded.profile.checks[0].timeoutSeconds == 600)
    #expect(loaded.profileHash.count == 64)

    try """
    {"version":1,"checks":[{"id":"bad id","name":"Bad","command":"true"}]}
    """.write(to: profileURL, atomically: true, encoding: .utf8)
    #expect(throws: VerificationError.self) {
        _ = try VerificationProfileLoader().load(from: root.path)
    }
}

@Test func fingerprintChangesForEveryMaterialGitLayer() throws {
    let root = try makeVerificationRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    try runVerificationGit(["switch", "-c", "feature/receipt"], in: root)
    let provider = ChangeFingerprintProvider()

    let initial = try provider.snapshot(
        rootPath: root.path,
        profileHash: "profile-a",
        configuredBase: "main"
    )
    try "changed\n".write(to: root.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
    let unstaged = try provider.snapshot(
        rootPath: root.path,
        profileHash: "profile-a",
        configuredBase: "main"
    )
    try runVerificationGit(["add", "App.swift"], in: root)
    let staged = try provider.snapshot(
        rootPath: root.path,
        profileHash: "profile-a",
        configuredBase: "main"
    )
    try "secret-one".write(to: root.appendingPathComponent("Notes.txt"), atomically: true, encoding: .utf8)
    let untracked = try provider.snapshot(
        rootPath: root.path,
        profileHash: "profile-a",
        configuredBase: "main"
    )
    try "secret-two".write(to: root.appendingPathComponent("Notes.txt"), atomically: true, encoding: .utf8)
    let untrackedContentChanged = try provider.snapshot(
        rootPath: root.path,
        profileHash: "profile-a",
        configuredBase: "main"
    )
    let profileChanged = try provider.snapshot(
        rootPath: root.path,
        profileHash: "profile-b",
        configuredBase: "main"
    )

    #expect(initial.fingerprint != unstaged.fingerprint)
    #expect(unstaged.fingerprint != staged.fingerprint)
    #expect(staged.fingerprint != untracked.fingerprint)
    #expect(untracked.fingerprint != untrackedContentChanged.fingerprint)
    #expect(untrackedContentChanged.fingerprint != profileChanged.fingerprint)
    #expect(untrackedContentChanged.changedFiles == 2)
}

@Test func serviceRequiresScopedTrustPersistsOnlyMetadataAndInvalidatesOnChange() async throws {
    let root = try makeVerificationRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    try runVerificationGit(["switch", "-c", "feature/service"], in: root)
    let profileURL = root.appendingPathComponent(".tilde/verify.json")
    let profileText = """
    {
      "version": 1,
      "base": "main",
      "checks": [
        {
          "id": "tests",
          "name": "Tests",
          "command": "printf ephemeral-secret",
          "required": true,
          "timeoutSeconds": 5
        }
      ]
    }
    """
    try profileText.write(to: profileURL, atomically: true, encoding: .utf8)

    let storeDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tilde-verification-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: storeDirectory) }
    let receiptURL = storeDirectory.appendingPathComponent("receipts.json")
    let trustURL = storeDirectory.appendingPathComponent("trust.json")
    let dismissalURL = storeDirectory.appendingPathComponent("dismissals.json")
    let service = VerificationService(
        receiptStore: VerificationReceiptStore(fileURL: receiptURL),
        trustStore: VerificationProfileTrustStore(fileURL: trustURL),
        dismissalStore: VerificationDismissalStore(fileURL: dismissalURL)
    )

    let before = await service.snapshot(rootPath: root.path)
    #expect(before.state == .untrusted)

    let displayedHash = try #require(before.loadedProfile?.profileHash)
    let verified = try await service.run(
        rootPath: root.path,
        trustingProfile: true,
        expectedProfileHash: displayedHash
    )
    #expect(verified.state == .verified)
    #expect(verified.outputExcerpt == "ephemeral-secret")
    let persisted = try String(contentsOf: receiptURL, encoding: .utf8)
    #expect(!persisted.contains("ephemeral-secret"))
    #expect(!persisted.contains("printf"))
    #expect(!persisted.contains(root.path))

    try profileText.replacingOccurrences(
        of: "printf ephemeral-secret",
        with: "printf changed-command"
    ).write(to: profileURL, atomically: true, encoding: .utf8)
    let changedProfile = await service.snapshot(rootPath: root.path)
    #expect(changedProfile.state == .untrusted)

    try profileText.write(to: profileURL, atomically: true, encoding: .utf8)
    let restoredProfile = await service.snapshot(rootPath: root.path)
    #expect(restoredProfile.state == .verified)

    try "changed after checks\n".write(
        to: root.appendingPathComponent("App.swift"),
        atomically: true,
        encoding: .utf8
    )
    let stale = await service.snapshot(rootPath: root.path)
    #expect(stale.state == .stale)

    let cleared = try await service.clearReceipt(rootPath: root.path)
    #expect(cleared.state == .dismissed)
    #expect(await service.snapshot(rootPath: root.path).state == .dismissed)
    let clearedStore = try String(contentsOf: receiptURL, encoding: .utf8)
    #expect(!clearedStore.contains(verified.changeSet?.worktreeID ?? "missing-worktree"))

    try "changed after dismissal\n".write(
        to: root.appendingPathComponent("App.swift"),
        atomically: true,
        encoding: .utf8
    )
    #expect(await service.snapshot(rootPath: root.path).state == .missing)
}

@Test func trustAndRunRejectsAProfileChangedAfterReview() async throws {
    let root = try makeVerificationRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("should-not-run")
    let profileURL = root.appendingPathComponent(".tilde/verify.json")
    try verificationProfile(command: "true").write(
        to: profileURL,
        atomically: true,
        encoding: .utf8
    )
    let service = VerificationService(
        receiptStore: VerificationReceiptStore(fileURL: root.appendingPathComponent("receipts.json")),
        trustStore: VerificationProfileTrustStore(fileURL: root.appendingPathComponent("trust.json")),
        dismissalStore: VerificationDismissalStore(fileURL: root.appendingPathComponent("dismissals.json"))
    )
    let displayed = await service.snapshot(rootPath: root.path)
    let displayedHash = try #require(displayed.loadedProfile?.profileHash)

    try verificationProfile(command: "touch \(shellQuote(marker.path))").write(
        to: profileURL,
        atomically: true,
        encoding: .utf8
    )
    await #expect(throws: VerificationError.profileChanged) {
        _ = try await service.run(
            rootPath: root.path,
            trustingProfile: true,
            expectedProfileHash: displayedHash
        )
    }
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test func receiptsAreScopedToOneWorktree() async throws {
    let root = try makeVerificationRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let sibling = FileManager.default.temporaryDirectory
        .appendingPathComponent("tilde-worktree-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sibling) }
    let profile = verificationProfile(command: "true")
    try profile.write(
        to: root.appendingPathComponent(".tilde/verify.json"),
        atomically: true,
        encoding: .utf8
    )
    try runVerificationGit(["worktree", "add", "-b", "sibling", sibling.path], in: root)
    try FileManager.default.createDirectory(
        at: sibling.appendingPathComponent(".tilde"),
        withIntermediateDirectories: true
    )
    try profile.write(
        to: sibling.appendingPathComponent(".tilde/verify.json"),
        atomically: true,
        encoding: .utf8
    )

    let storage = FileManager.default.temporaryDirectory
        .appendingPathComponent("tilde-worktree-store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storage) }
    let service = VerificationService(
        receiptStore: VerificationReceiptStore(fileURL: storage.appendingPathComponent("receipts.json")),
        trustStore: VerificationProfileTrustStore(fileURL: storage.appendingPathComponent("trust.json")),
        dismissalStore: VerificationDismissalStore(fileURL: storage.appendingPathComponent("dismissals.json"))
    )
    let first = await service.snapshot(rootPath: root.path)
    let hash = try #require(first.loadedProfile?.profileHash)
    let verified = try await service.run(
        rootPath: root.path,
        trustingProfile: true,
        expectedProfileHash: hash
    )
    #expect(verified.state == .verified)
    let siblingSnapshot = await service.snapshot(rootPath: sibling.path)
    #expect(siblingSnapshot.state == .missing)
    #expect(siblingSnapshot.changeSet?.worktreeID != verified.changeSet?.worktreeID)
}

@Test func fingerprintChangesWhenAnAlreadyDirtySubmoduleChangesAgain() throws {
    let submodule = try makeVerificationRepository()
    defer { try? FileManager.default.removeItem(at: submodule) }
    let root = try makeVerificationRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    try runVerificationGit(
        ["-c", "protocol.file.allow=always", "submodule", "add", submodule.path, "Vendor/Sub"],
        in: root
    )
    try runVerificationGit(["add", "."], in: root)
    try runVerificationGit([
        "-c", "user.name=Tilde Tests",
        "-c", "user.email=tilde@example.invalid",
        "commit", "-m", "Add submodule",
    ], in: root)
    let nestedFile = root.appendingPathComponent("Vendor/Sub/App.swift")
    let provider = ChangeFingerprintProvider()
    try "dirty one\n".write(to: nestedFile, atomically: true, encoding: .utf8)
    let first = try provider.snapshot(rootPath: root.path, profileHash: "profile", configuredBase: "main")
    try "dirty two\n".write(to: nestedFile, atomically: true, encoding: .utf8)
    let second = try provider.snapshot(rootPath: root.path, profileHash: "profile", configuredBase: "main")
    #expect(first.fingerprint != second.fingerprint)
}

@Test func runnerReportsFailureTimeoutAndCancellationWithoutPersistingOutput() async throws {
    let runner = VerificationCommandRunner()
    let failed = try await runner.run(
        checks: [VerificationCheck(id: "fail", name: "Fail", command: "echo failure; exit 7")],
        in: FileManager.default.temporaryDirectory.path
    )
    #expect(failed.receipts.first?.outcome == .failed)
    #expect(failed.receipts.first?.exitStatus == 7)
    #expect(failed.outputExcerpt?.contains("failure") == true)

    let timedOut = try await runner.run(
        checks: [VerificationCheck(
            id: "timeout",
            name: "Timeout",
            command: "sleep 5",
            timeoutSeconds: 1
        )],
        in: FileManager.default.temporaryDirectory.path
    )
    #expect(timedOut.receipts.first?.outcome == .timedOut)

    let task = Task {
        try await runner.run(
            checks: [VerificationCheck(
                id: "cancel",
                name: "Cancel",
                command: "sleep 5",
                timeoutSeconds: 10
            )],
            in: FileManager.default.temporaryDirectory.path
        )
    }
    try await Task.sleep(for: .milliseconds(100))
    await runner.cancel()
    let cancelled = try await task.value
    #expect(cancelled.receipts.first?.outcome == .cancelled)
}

@Test func timeoutTerminatesTheEntireCommandProcessGroup() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tilde-process-tree-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let leakedMarker = root.appendingPathComponent("descendant-survived")
    let command = "(trap '' TERM; sleep 3; touch \(shellQuote(leakedMarker.path))) & sleep 10"
    let result = try await VerificationCommandRunner().run(
        checks: [VerificationCheck(
            id: "tree-timeout",
            name: "Tree timeout",
            command: command,
            timeoutSeconds: 1
        )],
        in: root.path
    )
    #expect(result.receipts.first?.outcome == .timedOut)
    try await Task.sleep(for: .seconds(2.2))
    #expect(!FileManager.default.fileExists(atPath: leakedMarker.path))
}

@Test func backgroundDescendantCannotHoldTheRunnerPastItsBound() async throws {
    let clock = ContinuousClock()
    let elapsed = try await clock.measure {
        _ = try await VerificationCommandRunner().run(
            checks: [VerificationCheck(
                id: "background",
                name: "Background",
                command: "sleep 10 &",
                timeoutSeconds: 2
            )],
            in: FileManager.default.temporaryDirectory.path
        )
    }
    #expect(elapsed < .seconds(3))
}

private enum VerificationGitError: Error {
    case failed([String], Int32)
}

private func makeVerificationRepository() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tilde-verification-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent(".tilde", isDirectory: true),
        withIntermediateDirectories: true
    )
    try runVerificationGit(["init", "-b", "main"], in: root)
    try "initial\n".write(to: root.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
    try runVerificationGit(["add", "App.swift"], in: root)
    try runVerificationGit([
        "-c", "user.name=Tilde Tests",
        "-c", "user.email=tilde@example.invalid",
        "commit", "-m", "Initial",
    ], in: root)
    return root
}

private func runVerificationGit(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw VerificationGitError.failed(arguments, process.terminationStatus)
    }
}

private func verificationProfile(command: String) -> String {
    let encodedCommand = try! JSONEncoder().encode(command)
    let jsonCommand = String(decoding: encodedCommand, as: UTF8.self)
    return """
    {
      "version": 1,
      "base": "main",
      "checks": [
        {"id": "tests", "name": "Tests", "command": \(jsonCommand), "required": true, "timeoutSeconds": 10}
      ]
    }
    """
}

private func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}
