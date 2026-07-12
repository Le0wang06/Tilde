import Foundation
import Testing
@testable import TildeCore

@Test func herdrAgentListParsesAttentionAndProjectIdentity() throws {
    let json = #"""
    {
      "id": "cli:agent:list",
      "result": {
        "agents": [
          {
            "agent": "codex",
            "agent_status": "blocked",
            "cwd": "/tmp/example-project",
            "focused": true,
            "foreground_cwd": "/tmp/example-project",
            "pane_id": "w1:p1",
            "terminal_id": "term_123",
            "workspace_id": "w1"
          }
        ],
        "type": "agent_list"
      }
    }
    """#

    let snapshot = try HerdrAgentProvider.parseAgentList(Data(json.utf8))
    let agent = try #require(snapshot.agents.first)

    #expect(snapshot.providerAvailable)
    #expect(agent.id == "term_123")
    #expect(agent.state == .blocked)
    #expect(agent.projectName == "example-project")
    #expect(agent.focused)
    #expect(snapshot.attentionCount == 1)
}
@Test func attentionItemsPutBlockedAgentsBeforeCompletedAgents() {
    let snapshot = AgentAttentionSnapshot(
        agents: [
            makeAgent(id: "done", state: .done, project: "Alpha"),
            makeAgent(id: "working", state: .working, project: "Beta"),
            makeAgent(id: "blocked", state: .blocked, project: "Gamma"),
        ],
        providerAvailable: true
    )

    #expect(snapshot.attentionItems.map(\.id) == ["blocked", "done"])
    #expect(snapshot.workingCount == 1)
}

@Test func displayItemsIncludeIdleAgentsWithoutMarkingThemForAttention() {
    let snapshot = AgentAttentionSnapshot(
        agents: [
            makeAgent(id: "unknown", state: .unknown, project: "Unknown"),
            makeAgent(id: "idle", state: .idle, project: "Tilde"),
            makeAgent(id: "working", state: .working, project: "Beta"),
            makeAgent(id: "done", state: .done, project: "Alpha"),
            makeAgent(id: "blocked", state: .blocked, project: "Gamma"),
        ],
        providerAvailable: true
    )

    #expect(snapshot.displayItems.map(\.id) == ["blocked", "done", "working", "idle", "unknown"])
    #expect(snapshot.displayItems.contains { $0.state == .idle })
    #expect(snapshot.attentionCount == 2)
}

@Test func attentionMonitorSuppressesInitialAlertsAndReportsTransitions() async {
    let queue = AttentionSnapshotQueue([
        AgentAttentionSnapshot(
            agents: [makeAgent(id: "agent", state: .working)],
            providerAvailable: true
        ),
        AgentAttentionSnapshot(
            agents: [makeAgent(id: "agent", state: .blocked)],
            providerAvailable: true
        ),
        AgentAttentionSnapshot(
            agents: [makeAgent(id: "agent", state: .done)],
            providerAvailable: true
        ),
    ])
    let monitor = AgentAttentionMonitor { await queue.next() }

    let baseline = await monitor.refresh()
    let blocked = await monitor.refresh()
    let done = await monitor.refresh()

    #expect(baseline.events.isEmpty)
    #expect(blocked.events.map(\.kind) == [.needsInput])
    #expect(done.events.map(\.kind) == [.completed])
}

private actor AttentionSnapshotQueue {
    private var snapshots: [AgentAttentionSnapshot]

    init(_ snapshots: [AgentAttentionSnapshot]) {
        self.snapshots = snapshots
    }

    func next() -> AgentAttentionSnapshot {
        snapshots.removeFirst()
    }
}

private func makeAgent(
    id: String,
    state: AgentAttentionState,
    project: String = "Tilde"
) -> AgentAttentionItem {
    AgentAttentionItem(
        id: id,
        terminalID: id,
        paneID: nil,
        workspaceID: "w1",
        agent: "codex",
        state: state,
        cwd: "/tmp/\(project)",
        projectRoot: "/tmp/\(project)",
        projectName: project,
        branch: "main",
        focused: false
    )
}
