import Foundation

public struct RecoveryCapsule: Codable, Sendable, Equatable {
    public var projectRoot: String
    public var projectName: String
    public var branch: String?
    public var updatedAt: Date
    public var headline: String
    public var nextAction: String
    public var attentionCount: Int
    public var verificationState: String
    public var changedFiles: Int

    public init(
        projectRoot: String,
        projectName: String,
        branch: String?,
        updatedAt: Date = Date(),
        headline: String,
        nextAction: String,
        attentionCount: Int,
        verificationState: String,
        changedFiles: Int
    ) {
        self.projectRoot = projectRoot
        self.projectName = projectName
        self.branch = branch
        self.updatedAt = updatedAt
        self.headline = headline
        self.nextAction = nextAction
        self.attentionCount = attentionCount
        self.verificationState = verificationState
        self.changedFiles = changedFiles
    }
}
public actor RecoveryCapsuleStore {
    private let fileURL: URL
    private var capsules: [String: RecoveryCapsule]?

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let directory = base.appendingPathComponent("Tilde", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appendingPathComponent("recovery-capsules.json")
        }
    }

    public func update(
        project: ProjectContextSnapshot,
        attention: AgentAttentionSnapshot,
        trust: TrustPacketSnapshot,
        build: BuildPulseSnapshot
    ) -> RecoveryCapsule? {
        guard let root = project.rootPath else { return nil }
        loadIfNeeded()
        let projectAgents = attention.agents.filter { $0.projectRoot == root }
        let needsInput = projectAgents.first { $0.state == .blocked }
        let completed = projectAgents.first { $0.state == .done }

        let headline: String
        let nextAction: String
        if let needsInput {
            headline = "\(needsInput.agent.capitalized) needs input"
            nextAction = "Return to the agent and answer its blocker"
        } else if let completed {
            headline = "\(completed.agent.capitalized) is ready to review"
            nextAction = "Review the agent changes and verification evidence"
        } else if build.phase == .running {
            headline = build.statusText
            nextAction = "Wait for the build result"
        } else if trust.state == .needsVerification {
            headline = trust.summary
            nextAction = trust.risks.first?.message ?? "Run the project checks"
        } else if trust.changedFiles > 0 {
            headline = trust.summary
            nextAction = "Review and commit the local changes"
        } else {
            headline = "Project is clean"
            nextAction = "Choose the next project task"
        }

        var capsule = RecoveryCapsule(
            projectRoot: root,
            projectName: project.projectName ?? URL(fileURLWithPath: root).lastPathComponent,
            branch: project.branch,
            headline: headline,
            nextAction: nextAction,
            attentionCount: projectAgents.filter { $0.state.needsAttention }.count,
            verificationState: trust.state.rawValue,
            changedFiles: trust.changedFiles
        )
        if let previous = capsules?[root], previous.matchesState(of: capsule) {
            capsule.updatedAt = previous.updatedAt
            return previous
        }

        capsules?[root] = capsule
        save()
        return capsule
    }

    public func capsule(for root: String) -> RecoveryCapsule? {
        loadIfNeeded()
        return capsules?[root]
    }

    private func loadIfNeeded() {
        guard capsules == nil else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.tilde.decode([String: RecoveryCapsule].self, from: data) else {
            capsules = [:]
            return
        }
        capsules = decoded
    }

    private func save() {
        guard let capsules,
              let data = try? JSONEncoder.tilde.encode(capsules) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private extension RecoveryCapsule {
    func matchesState(of other: RecoveryCapsule) -> Bool {
        projectRoot == other.projectRoot
            && projectName == other.projectName
            && branch == other.branch
            && headline == other.headline
            && nextAction == other.nextAction
            && attentionCount == other.attentionCount
            && verificationState == other.verificationState
            && changedFiles == other.changedFiles
    }
}

private extension JSONEncoder {
    static var tilde: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var tilde: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
