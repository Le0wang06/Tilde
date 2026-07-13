import Testing
import TildeCore

@Suite("Decision queue ranking")
struct DecisionQueueTests {
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
        #expect(messages.contains("Exact checks passed for this change"))
        #expect(messages.contains("Authentication files changed"))
        #expect(messages.contains("CI has not run for this commit"))
        #expect(queue.topItem?.actions.contains(where: { $0.kind == .reviewChange }) == true)
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
}
