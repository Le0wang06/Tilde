import Foundation
import Testing
@testable import TildeCore

@Test func recoveryCapsulePrioritizesBlockedAgentAndPersistsMetadata() async throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("tilde-recovery-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let store = RecoveryCapsuleStore(fileURL: fileURL)
    let project = ProjectContextSnapshot(
        projectName: "Tilde",
        rootPath: "/tmp/Tilde",
        branch: "feature/attention",
        isDirty: true
    )
    let attention = AgentAttentionSnapshot(
        agents: [AgentAttentionItem(
            id: "agent",
            terminalID: "agent",
            paneID: "w1:p1",
            workspaceID: "w1",
            agent: "codex",
            state: .blocked,
            cwd: "/tmp/Tilde",
            projectRoot: "/tmp/Tilde",
            projectName: "Tilde",
            branch: "feature/attention",
            focused: false
        )],
        providerAvailable: true
    )
    let trust = TrustPacketSnapshot(
        state: .needsVerification,
        projectRoot: "/tmp/Tilde",
        changedFiles: 4,
        risks: [TrustRisk(kind: .buildUnknown, message: "Run checks")]
    )

    let capsule = try #require(await store.update(
        project: project,
        attention: attention,
        trust: trust,
        build: BuildPulseSnapshot()
    ))
    #expect(capsule.headline == "Codex needs input")
    #expect(capsule.attentionCount == 1)

    let restored = await RecoveryCapsuleStore(fileURL: fileURL).capsule(for: "/tmp/Tilde")
    #expect(restored?.projectRoot == capsule.projectRoot)
    #expect(restored?.headline == capsule.headline)
    #expect(restored?.nextAction == capsule.nextAction)
    #expect(restored?.attentionCount == capsule.attentionCount)
    #expect(abs((restored?.updatedAt.timeIntervalSince1970 ?? 0) - capsule.updatedAt.timeIntervalSince1970) < 1)
}
