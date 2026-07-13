import Foundation
import Testing
@testable import TildeCore

@Test func numstatParserCountsTextChangesAndIgnoresBinaryMarkers() {
    let parsed = TrustPacketProvider.parseNumstat("12\t3\tSources/App.swift\n-\t-\tasset.png\n4\t0\tREADME.md\n")
    #expect(parsed.additions == 16)
    #expect(parsed.deletions == 3)
}
@Test func sensitivePathDetectionCoversHighRiskProjectFiles() {
    #expect(TrustPacketProvider.isSensitivePath("Package.swift"))
    #expect(TrustPacketProvider.isSensitivePath(".github/workflows/release.yml"))
    #expect(TrustPacketProvider.isSensitivePath("App/Auth/Login.swift"))
    #expect(!TrustPacketProvider.isSensitivePath("Sources/MetricVisuals.swift"))
}


@Test func trustPacketIncludesCommittedBranchChangesAndDoesNotClaimObservedBuildAsProof() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tilde-trust-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try runGit(["init", "-b", "main"], in: root)
    try "initial\n".write(to: root.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
    try runGit(["add", "App.swift"], in: root)
    try runGit(["-c", "user.name=Tilde Tests", "-c", "user.email=tilde@example.invalid", "commit", "-m", "Initial"], in: root)
    try runGit(["switch", "-c", "feature/trust"], in: root)
    try "initial\nchanged\n".write(to: root.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
    try runGit(["add", "App.swift"], in: root)
    try runGit(["-c", "user.name=Tilde Tests", "-c", "user.email=tilde@example.invalid", "commit", "-m", "Change"], in: root)

    let snapshot = await TrustPacketProvider().snapshot(
        rootPath: root.path,
        build: BuildPulseSnapshot(phase: .finished, lastSucceeded: true),
        ciStatus: .success,
        behind: nil
    )

    #expect(snapshot.changedFiles == 1)
    #expect(snapshot.additions == 1)
    #expect(snapshot.comparisonBase == "main")
    #expect(snapshot.state == .needsVerification)
    #expect(snapshot.risks.contains { $0.kind == .buildUnknown })
    #expect(snapshot.risks.first { $0.kind == .buildUnknown }?.message.contains("not bound") == true)
}

@Test func trustPacketDoesNotApplyHeadCIToUncommittedChanges() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tilde-trust-local-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try runGit(["init", "-b", "main"], in: root)
    try "initial\n".write(to: root.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
    try runGit(["add", "App.swift"], in: root)
    try runGit(["-c", "user.name=Tilde Tests", "-c", "user.email=tilde@example.invalid", "commit", "-m", "Initial"], in: root)
    try "local change\n".write(to: root.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
    try "untracked\n".write(to: root.appendingPathComponent("Notes.txt"), atomically: true, encoding: .utf8)

    let snapshot = await TrustPacketProvider().snapshot(
        rootPath: root.path,
        build: BuildPulseSnapshot(),
        ciStatus: .success,
        behind: nil
    )

    #expect(snapshot.risks.contains { $0.kind == .ciUnknown })
    #expect(snapshot.risks.first { $0.kind == .ciUnknown }?.message.contains("local changes") == true)
    #expect(snapshot.changedFiles == 2)
    #expect(snapshot.untrackedFiles == 1)
}

@Test func trustPacketFindsNonMainLocalBaseBranch() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tilde-trust-trunk-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try runGit(["init", "-b", "trunk"], in: root)
    try "initial\n".write(to: root.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
    try runGit(["add", "App.swift"], in: root)
    try runGit(["-c", "user.name=Tilde Tests", "-c", "user.email=tilde@example.invalid", "commit", "-m", "Initial"], in: root)
    try runGit(["switch", "-c", "feature/trunk-base"], in: root)
    try "initial\nfeature\n".write(to: root.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
    try runGit(["add", "App.swift"], in: root)
    try runGit(["-c", "user.name=Tilde Tests", "-c", "user.email=tilde@example.invalid", "commit", "-m", "Feature"], in: root)

    let snapshot = await TrustPacketProvider().snapshot(
        rootPath: root.path,
        build: BuildPulseSnapshot(),
        ciStatus: .unknown,
        behind: nil
    )

    #expect(snapshot.comparisonBase == "trunk")
    #expect(snapshot.changedFiles == 1)
    #expect(snapshot.additions == 1)
}

private enum GitTestError: Error {
    case failed(arguments: [String], status: Int32)
}

private func runGit(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw GitTestError.failed(arguments: arguments, status: process.terminationStatus)
    }
}
