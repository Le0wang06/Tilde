import Foundation

/// Pure, deterministic composer that turns existing evidence into a change-centered decision queue.
public enum DecisionQueueComposer {
    public static func compose(
        project: ProjectContextSnapshot,
        trust: TrustPacketSnapshot,
        verification: VerificationSnapshot,
        agents: AgentAttentionSnapshot,
        build: BuildPulseSnapshot = BuildPulseSnapshot()
    ) -> DecisionQueueSnapshot {
        _ = build

        var buckets: [String: Bucket] = [:]

        if let root = project.rootPath, !root.isEmpty {
            let key = canonicalize(root)
            buckets[key] = Bucket(
                worktreePath: root,
                projectName: project.projectName ?? URL(fileURLWithPath: root).lastPathComponent,
                branch: project.branch,
                trust: trust,
                verification: verification,
                agents: []
            )
        }

        for agent in agents.agents {
            let root = agent.projectRoot ?? agent.cwd
            let key = canonicalize(root)
            var bucket = buckets[key] ?? Bucket(
                worktreePath: root,
                projectName: agent.projectName,
                branch: agent.branch,
                trust: .unavailable,
                verification: .unavailable,
                agents: []
            )
            if bucket.branch == nil { bucket.branch = agent.branch }
            if bucket.projectName.isEmpty { bucket.projectName = agent.projectName }
            bucket.agents.append(agent)
            // Prefer exact trust/verification when this agent is on the active project.
            if let projectRoot = project.rootPath, canonicalize(projectRoot) == key {
                bucket.trust = trust
                bucket.verification = verification
                if let name = project.projectName { bucket.projectName = name }
                if let branch = project.branch { bucket.branch = branch }
            }
            buckets[key] = bucket
        }

        let items = buckets.values
            .map(makeItem(from:))
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                let nameOrder = lhs.projectName.localizedCaseInsensitiveCompare(rhs.projectName)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.worktreePath < rhs.worktreePath
            }

        let workingCount = agents.agents.filter { $0.state == .working }.count
        let idleCount = agents.agents.filter { $0.state == .idle || $0.state == .unknown }.count
        return DecisionQueueSnapshot(
            items: items,
            workingCount: workingCount,
            idleCount: idleCount,
            sampledAt: Date()
        )
    }

    private struct Bucket {
        var worktreePath: String
        var projectName: String
        var branch: String?
        var trust: TrustPacketSnapshot
        var verification: VerificationSnapshot
        var agents: [AgentAttentionItem]
    }

    private static func makeItem(from bucket: Bucket) -> DecisionQueueItem {
        let reasons = reasons(for: bucket)
        let priority = priority(for: bucket, reasons: reasons)
        let needsYou = priority <= 5
        let subtitle = subtitle(for: bucket, priority: priority)
        let branchLabel = bucket.branch ?? "detached"
        let title = "\(bucket.projectName) · \(branchLabel)"
        let terminalIDs = bucket.agents.map(\.terminalID)
        let actions = actions(for: bucket)

        return DecisionQueueItem(
            id: canonicalize(bucket.worktreePath),
            title: title,
            subtitle: subtitle,
            projectName: bucket.projectName,
            branch: bucket.branch,
            worktreePath: bucket.worktreePath,
            reasons: reasons,
            actions: actions,
            agentTerminalIDs: terminalIDs,
            priority: priority,
            needsYou: needsYou
        )
    }

    private static func reasons(for bucket: Bucket) -> [DecisionReason] {
        var reasons: [DecisionReason] = []

        if bucket.agents.contains(where: { $0.state == .blocked }) {
            reasons.append(.init(
                kind: .agentBlocked,
                severity: .fail,
                message: "Agent is blocked and waiting for input"
            ))
        }
        if bucket.agents.contains(where: { $0.state == .done }) {
            reasons.append(.init(
                kind: .agentReady,
                severity: .warn,
                message: "Agent marked this change ready to review"
            ))
        }

        switch bucket.verification.state {
        case .verified:
            reasons.append(.init(
                kind: .verificationPassed,
                severity: .pass,
                message: "Exact checks passed for this change"
            ))
        case .failed:
            reasons.append(.init(
                kind: .verificationFailed,
                severity: .fail,
                message: bucket.verification.summary
            ))
        case .stale:
            reasons.append(.init(
                kind: .verificationStale,
                severity: .warn,
                message: "Previously verified evidence is stale for this change"
            ))
        case .missing:
            reasons.append(.init(
                kind: .verificationMissing,
                severity: .warn,
                message: "Required checks have not run for this exact change"
            ))
        case .untrusted:
            reasons.append(.init(
                kind: .verificationUntrusted,
                severity: .warn,
                message: "Verification profile needs trust before checks can run"
            ))
        case .running:
            reasons.append(.init(
                kind: .verificationRunning,
                severity: .info,
                message: bucket.verification.summary
            ))
        case .unavailable, .unconfigured, .dismissed, .partial:
            break
        }

        for risk in bucket.trust.risks {
            switch risk.kind {
            case .sensitiveFiles:
                reasons.append(.init(kind: .sensitiveFiles, severity: .warn, message: risk.message))
            case .ciPending:
                reasons.append(.init(kind: .ciPending, severity: .warn, message: risk.message))
            case .ciFailed:
                reasons.append(.init(kind: .ciFailed, severity: .fail, message: risk.message))
            case .ciUnknown:
                reasons.append(.init(kind: .ciUnknown, severity: .warn, message: risk.message))
            case .largeChange:
                reasons.append(.init(kind: .largeChange, severity: .warn, message: risk.message))
            case .branchBehind:
                reasons.append(.init(kind: .branchBehind, severity: .warn, message: risk.message))
            case .verificationMissing, .verificationFailed, .verificationStale, .buildUnknown, .buildFailed:
                // Covered by verification / build context elsewhere.
                break
            }
        }

        if bucket.trust.changedFiles > 0 || bucket.trust.untrackedFiles > 0 {
            if !reasons.contains(where: {
                $0.kind == .dirtyChange || $0.kind == .largeChange || $0.kind == .verificationPassed
            }) {
                let count = bucket.trust.changedFiles + bucket.trust.untrackedFiles
                reasons.append(.init(
                    kind: .dirtyChange,
                    severity: .info,
                    message: "\(count) file\(count == 1 ? "" : "s") changed versus \(bucket.trust.comparisonBase ?? "base")"
                ))
            }
        }

        if bucket.agents.contains(where: { $0.state == .working }),
           !reasons.contains(where: { $0.kind == .agentBlocked || $0.kind == .agentReady }) {
            reasons.append(.init(
                kind: .working,
                severity: .info,
                message: "Agent is still working in this worktree"
            ))
        }

        if reasons.isEmpty {
            reasons.append(.init(
                kind: .idle,
                severity: .info,
                message: "No decision required right now"
            ))
        }

        return Array(reasons.prefix(5))
    }

    private static func priority(for bucket: Bucket, reasons: [DecisionReason]) -> Int {
        if reasons.contains(where: { $0.kind == .agentBlocked }) { return 0 }
        if reasons.contains(where: { $0.kind == .verificationFailed }) { return 1 }
        if reasons.contains(where: { $0.kind == .verificationStale }) { return 2 }
        if reasons.contains(where: { $0.kind == .verificationMissing || $0.kind == .verificationUntrusted }) {
            return 3
        }
        if reasons.contains(where: { $0.kind == .agentReady }) { return 4 }
        if reasons.contains(where: { $0.kind == .ciFailed || $0.kind == .sensitiveFiles }) { return 5 }
        if reasons.contains(where: { $0.kind == .working || $0.kind == .verificationRunning }) { return 6 }
        if reasons.contains(where: { $0.kind == .verificationPassed }) { return 7 }
        return 8
    }

    private static func subtitle(for bucket: Bucket, priority: Int) -> String {
        switch priority {
        case 0: return "Needs input"
        case 1: return "Checks failed"
        case 2: return "Evidence went stale"
        case 3: return "Checks missing"
        case 4: return "Ready for review"
        case 5: return "Review with caution"
        case 6: return "Working"
        case 7: return "Verified · ready for review"
        default: return "Idle"
        }
    }

    private static func actions(for bucket: Bucket) -> [DecisionAction] {
        var actions: [DecisionAction] = [
            .init(kind: .reviewChange, title: "Review Change"),
        ]

        switch bucket.verification.state {
        case .untrusted:
            actions.append(.init(kind: .trustProfile, title: "Trust Profile"))
        case .missing, .failed, .stale, .partial, .verified, .dismissed:
            actions.append(.init(kind: .runChecks, title: "Run Checks"))
        case .running:
            actions.append(.init(kind: .runChecks, title: "Run Checks", isEnabled: false))
        case .unavailable, .unconfigured:
            break
        }

        if !bucket.agents.isEmpty {
            actions.append(.init(kind: .openAgent, title: "Open Agent"))
        }

        return actions
    }

    private static func canonicalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
