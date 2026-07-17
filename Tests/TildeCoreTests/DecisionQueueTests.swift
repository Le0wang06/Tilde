import Foundation
import Testing
@testable import TildeCore

@Suite("Decision queue ranking")
struct DecisionQueueTests {
    @Test("Git worktree porcelain preserves branches, detached state, and paths with spaces")
    func parsesWorktreePorcelain() throws {
        let parsed = GitWorktreeDiscovery.parsePorcelain(
            """
            worktree /tmp/repo
            HEAD abc123
            branch refs/heads/main

            worktree /tmp/repo worktrees/feature one
            HEAD def456
            detached
            locked maintenance

            """,
            repositoryID: "/tmp/repo/.git"
        )

        #expect(parsed.count == 2)
        #expect(parsed[0].branch == "main")
        #expect(parsed[0].isDetached == false)
        #expect(parsed[1].path == "/tmp/repo worktrees/feature one")
        #expect(parsed[1].isDetached)
        #expect(parsed[1].isLocked)
    }

    @Test("Discovery returns every linked worktree without mutating the repository")
    func discoversLinkedWorktreesReadOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tilde-worktrees-\(UUID().uuidString)", isDirectory: true)
        let linked = root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-linked", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: linked)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: root.path)
        try runGit(["config", "user.email", "tilde@example.test"], in: root.path)
        try runGit(["config", "user.name", "Tilde Tests"], in: root.path)
        let marker = root.appendingPathComponent("marker.txt")
        try Data("initial\n".utf8).write(to: marker)
        try runGit(["add", "marker.txt"], in: root.path)
        try runGit(["commit", "-m", "initial"], in: root.path)
        try runGit(["worktree", "add", "-b", "feature/linked", linked.path], in: root.path)
        let before = try runGit(["status", "--porcelain"], in: root.path)

        let snapshot = await GitWorktreeDiscovery().snapshot(seedPaths: [root.path, linked.path])
        let after = try runGit(["status", "--porcelain"], in: root.path)

        #expect(snapshot.worktrees.count == 2)
        #expect(Set(snapshot.worktrees.map(\.branch)) == Set(["main", "feature/linked"]))
        #expect(before == after)
        #expect(snapshot.notes.isEmpty)
    }

    @Test("Blocked agent outranks ready verified review")
    func blockedOutranksReady() {
        let project = ProjectContextSnapshot(
            projectName: "demo-app",
            rootPath: "/tmp/demo-app",
            branch: "feature/auth"
        )
        let ready = DecisionQueueComposer.compose(
            project: project,
            trust: TrustPacketSnapshot(state: .ready, projectRoot: "/tmp/demo-app", changedFiles: 2),
            verification: VerificationSnapshot(state: .verified, projectRoot: "/tmp/demo-app"),
            agents: AgentAttentionSnapshot(agents: [
                agent(id: "1", root: "/tmp/demo-app", name: "demo-app", state: .done, branch: "feature/auth"),
            ], providerAvailable: true)
        )
        #expect(ready.topItem?.subtitle == "Ready for review" || ready.topItem?.subtitle == "Verified · ready for review")

        let blocked = DecisionQueueComposer.compose(
            project: project,
            trust: TrustPacketSnapshot(state: .ready, projectRoot: "/tmp/demo-app", changedFiles: 2),
            verification: VerificationSnapshot(state: .verified, projectRoot: "/tmp/demo-app"),
            agents: AgentAttentionSnapshot(agents: [
                agent(id: "1", root: "/tmp/demo-app", name: "demo-app", state: .blocked, branch: "feature/auth"),
            ], providerAvailable: true)
        )
        #expect(blocked.topItem?.priority == 0)
        #expect(blocked.topItem?.subtitle == "Needs input")
        #expect(blocked.topItem!.priority < ready.topItem!.priority)
    }

    @Test("Failed verification outranks ready verified review")
    func failedOutranksVerified() {
        let project = ProjectContextSnapshot(
            projectName: "demo-app",
            rootPath: "/tmp/demo-app",
            branch: "main"
        )
        let failed = DecisionQueueComposer.compose(
            project: project,
            trust: TrustPacketSnapshot(state: .needsVerification, projectRoot: "/tmp/demo-app", changedFiles: 1),
            verification: VerificationSnapshot(state: .failed, projectRoot: "/tmp/demo-app", message: "Tests failed"),
            agents: AgentAttentionSnapshot(agents: [
                agent(id: "1", root: "/tmp/demo-app", name: "demo-app", state: .done, branch: "main"),
            ], providerAvailable: true)
        )
        let verified = DecisionQueueComposer.compose(
            project: project,
            trust: TrustPacketSnapshot(state: .ready, projectRoot: "/tmp/demo-app", changedFiles: 1),
            verification: VerificationSnapshot(state: .verified, projectRoot: "/tmp/demo-app"),
            agents: AgentAttentionSnapshot(agents: [
                agent(id: "1", root: "/tmp/demo-app", name: "demo-app", state: .done, branch: "main"),
            ], providerAvailable: true)
        )
        #expect(failed.topItem?.priority == 1)
        #expect(failed.topItem!.priority < verified.topItem!.priority)
    }

    @Test("Two agents in one worktree become one card")
    func agentsCollapseToOneChange() {
        let project = ProjectContextSnapshot(
            projectName: "demo-app",
            rootPath: "/tmp/demo-app",
            branch: "main"
        )
        let queue = DecisionQueueComposer.compose(
            project: project,
            trust: TrustPacketSnapshot(state: .ready, projectRoot: "/tmp/demo-app", changedFiles: 1),
            verification: VerificationSnapshot(state: .missing, projectRoot: "/tmp/demo-app"),
            agents: AgentAttentionSnapshot(agents: [
                agent(id: "a", root: "/tmp/demo-app", name: "demo-app", state: .working, branch: "main"),
                agent(id: "b", root: "/tmp/demo-app", name: "demo-app", state: .idle, branch: "main"),
            ], providerAvailable: true)
        )
        #expect(queue.items.count == 1)
        #expect(queue.items[0].agentTerminalIDs.count == 2)
        #expect(queue.items[0].needsYou == false)
        #expect(queue.workingCount == 1)
        #expect(queue.idleCount == 0)
    }

    @Test("Separate worktrees become separate cards")
    func separateWorktrees() {
        let project = ProjectContextSnapshot(
            projectName: "demo-app",
            rootPath: "/tmp/demo-app",
            branch: "main"
        )
        let queue = DecisionQueueComposer.compose(
            project: project,
            trust: TrustPacketSnapshot(state: .ready, projectRoot: "/tmp/demo-app", changedFiles: 0),
            verification: .unavailable,
            agents: AgentAttentionSnapshot(agents: [
                agent(id: "a", root: "/tmp/demo-app", name: "demo-app", state: .idle, branch: "main"),
                agent(id: "b", root: "/tmp/other-app", name: "other-app", state: .blocked, branch: "fix"),
            ], providerAvailable: true)
        )
        #expect(queue.items.count == 2)
        #expect(queue.topItem?.projectName == "other-app")
        #expect(queue.topItem?.subtitle == "Needs input")
    }

    @Test("Exact evidence for each worktree stays attached to its own card")
    func evidenceStaysScopedToWorktree() {
        let first = DecisionQueueEvidence(
            project: ProjectContextSnapshot(
                projectName: "repo-main",
                rootPath: "/tmp/repo",
                branch: "main"
            ),
            trust: TrustPacketSnapshot(state: .ready, projectRoot: "/tmp/repo", changedFiles: 1),
            verification: VerificationSnapshot(state: .failed, projectRoot: "/tmp/repo")
        )
        let second = DecisionQueueEvidence(
            project: ProjectContextSnapshot(
                projectName: "repo-feature",
                rootPath: "/tmp/repo-feature",
                branch: "feature/one",
                pullRequestURL: "https://example.test/pr/1"
            ),
            trust: TrustPacketSnapshot(state: .ready, projectRoot: "/tmp/repo-feature", changedFiles: 2),
            verification: VerificationSnapshot(state: .verified, projectRoot: "/tmp/repo-feature")
        )

        let queue = DecisionQueueComposer.compose(
            changes: [second, first],
            agents: AgentAttentionSnapshot(agents: [], providerAvailable: true)
        )

        #expect(queue.items.count == 2)
        #expect(queue.items[0].worktreePath == "/tmp/repo")
        #expect(queue.items[0].subtitle == "Checks failed")
        let feature = queue.items.first(where: { $0.worktreePath == "/tmp/repo-feature" })
        #expect(feature?.needsYou == true)
        #expect(feature?.actions.contains(where: { $0.kind == .openPullRequest }) == true)
        #expect(feature?.pullRequestURL == "https://example.test/pr/1")
    }

    @Test("Sensitive files and missing CI appear as factual reasons")
    func trustReasonsSurface() {
        let project = ProjectContextSnapshot(
            projectName: "demo-app",
            rootPath: "/tmp/demo-app",
            branch: "feature/auth-fix"
        )
        let queue = DecisionQueueComposer.compose(
            project: project,
            trust: TrustPacketSnapshot(
                state: .needsVerification,
                projectRoot: "/tmp/demo-app",
                changedFiles: 3,
                risks: [
                    TrustRisk(kind: .sensitiveFiles, message: "Authentication files changed"),
                    TrustRisk(kind: .ciUnknown, message: "CI has not run for this commit"),
                ]
            ),
            verification: VerificationSnapshot(state: .verified, projectRoot: "/tmp/demo-app"),
            agents: AgentAttentionSnapshot(agents: [
                agent(id: "1", root: "/tmp/demo-app", name: "demo-app", state: .done, branch: "feature/auth-fix"),
            ], providerAvailable: true)
        )
        let messages = queue.topItem?.reasons.map(\.message) ?? []
        // Warn/fail reasons win the 3-slot budget over the pass line.
        #expect(messages.contains("Ready for your review"))
        #expect(messages.contains("Authentication files changed"))
        #expect(messages.contains("CI has not run for this commit"))
        #expect(queue.topItem?.primaryAction?.kind == .reviewChange)
        #expect(queue.topItem?.actions.contains(where: { $0.kind == .runChecks }) == true)
        #expect(queue.topItem?.actions.contains(where: { $0.kind == .openAgent }) == true)
    }

    @Test("Ordering is deterministic across repeated samples")
    func deterministicOrdering() {
        let project = ProjectContextSnapshot(projectName: "zeta", rootPath: "/tmp/zeta", branch: "main")
        let agents = AgentAttentionSnapshot(agents: [
            agent(id: "b", root: "/tmp/alpha", name: "alpha", state: .working, branch: "main"),
            agent(id: "a", root: "/tmp/beta", name: "beta", state: .working, branch: "main"),
        ], providerAvailable: true)
        let first = DecisionQueueComposer.compose(
            project: project,
            trust: .unavailable,
            verification: .unavailable,
            agents: agents
        )
        let second = DecisionQueueComposer.compose(
            project: project,
            trust: .unavailable,
            verification: .unavailable,
            agents: agents
        )
        #expect(first.items.map(\.id) == second.items.map(\.id))
    }

    private func agent(
        id: String,
        root: String,
        name: String,
        state: AgentAttentionState,
        branch: String?
    ) -> AgentAttentionItem {
        AgentAttentionItem(
            id: id,
            terminalID: id,
            paneID: nil,
            workspaceID: nil,
            agent: "codex",
            state: state,
            cwd: root,
            projectRoot: root,
            projectName: name,
            branch: branch,
            focused: false
        )
    }

    @discardableResult
    private func runGit(_ arguments: [String], in directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "DecisionQueueTests.Git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: errorData, as: UTF8.self)]
            )
        }
        return String(decoding: data, as: UTF8.self)
    }
}
