import Foundation

public struct VerificationCheck: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let command: String
    public let required: Bool
    public let timeoutSeconds: Int

    public init(
        id: String,
        name: String,
        command: String,
        required: Bool = true,
        timeoutSeconds: Int = 600
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.required = required
        self.timeoutSeconds = timeoutSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case command
        case required
        case timeoutSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? true
        timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 600
    }
}

public struct VerificationProfile: Codable, Sendable, Equatable {
    public let version: Int
    public let base: String?
    public let checks: [VerificationCheck]

    public init(version: Int = 1, base: String? = nil, checks: [VerificationCheck]) {
        self.version = version
        self.base = base
        self.checks = checks
    }
}

public struct LoadedVerificationProfile: Sendable, Equatable {
    public let profile: VerificationProfile
    public let profileHash: String
    public let filePath: String

    public init(profile: VerificationProfile, profileHash: String, filePath: String) {
        self.profile = profile
        self.profileHash = profileHash
        self.filePath = filePath
    }
}

public struct ChangeFingerprint: Codable, Sendable, Equatable, Hashable {
    public let value: String

    public init(value: String) {
        self.value = value
    }

    public var shortValue: String {
        String(value.prefix(8))
    }
}

public struct ChangeSet: Sendable, Equatable {
    public let repositoryID: String
    public let worktreeID: String
    public let worktreePath: String
    public let baseRef: String
    public let baseOID: String
    public let mergeBaseOID: String
    public let headOID: String
    public let changedFiles: Int
    public let fingerprint: ChangeFingerprint
    public let sampledAt: Date

    public init(
        repositoryID: String,
        worktreeID: String,
        worktreePath: String,
        baseRef: String,
        baseOID: String,
        mergeBaseOID: String,
        headOID: String,
        changedFiles: Int,
        fingerprint: ChangeFingerprint,
        sampledAt: Date = Date()
    ) {
        self.repositoryID = repositoryID
        self.worktreeID = worktreeID
        self.worktreePath = worktreePath
        self.baseRef = baseRef
        self.baseOID = baseOID
        self.mergeBaseOID = mergeBaseOID
        self.headOID = headOID
        self.changedFiles = changedFiles
        self.fingerprint = fingerprint
        self.sampledAt = sampledAt
    }
}

public enum CheckReceiptOutcome: String, Codable, Sendable, Equatable {
    case passed
    case failed
    case timedOut
    case cancelled
}

public struct CheckReceipt: Codable, Sendable, Equatable, Identifiable {
    public var id: String { checkID }
    public let checkID: String
    public let checkName: String
    public let commandHash: String
    public let required: Bool
    public let startedAt: Date
    public let finishedAt: Date
    public let duration: TimeInterval
    public let exitStatus: Int32?
    public let outcome: CheckReceiptOutcome

    public init(
        checkID: String,
        checkName: String,
        commandHash: String,
        required: Bool,
        startedAt: Date,
        finishedAt: Date,
        duration: TimeInterval,
        exitStatus: Int32?,
        outcome: CheckReceiptOutcome
    ) {
        self.checkID = checkID
        self.checkName = checkName
        self.commandHash = commandHash
        self.required = required
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.duration = duration
        self.exitStatus = exitStatus
        self.outcome = outcome
    }
}

public struct VerificationRecord: Codable, Sendable, Equatable {
    public let repositoryID: String
    public let worktreeID: String
    public let baseOID: String
    public let mergeBaseOID: String
    public let headOID: String
    public let fingerprint: ChangeFingerprint
    public let profileHash: String
    public let receipts: [CheckReceipt]
    public let updatedAt: Date

    public init(
        repositoryID: String,
        worktreeID: String,
        baseOID: String,
        mergeBaseOID: String,
        headOID: String,
        fingerprint: ChangeFingerprint,
        profileHash: String,
        receipts: [CheckReceipt],
        updatedAt: Date = Date()
    ) {
        self.repositoryID = repositoryID
        self.worktreeID = worktreeID
        self.baseOID = baseOID
        self.mergeBaseOID = mergeBaseOID
        self.headOID = headOID
        self.fingerprint = fingerprint
        self.profileHash = profileHash
        self.receipts = receipts
        self.updatedAt = updatedAt
    }
}

public enum VerificationState: String, Sendable, Equatable {
    case unavailable
    case unconfigured
    case untrusted
    case missing
    case dismissed
    case running
    case failed
    case partial
    case verified
    case stale

    public var label: String {
        switch self {
        case .unavailable: return "Unavailable"
        case .unconfigured: return "No profile"
        case .untrusted: return "Review profile"
        case .missing: return "Checks missing"
        case .dismissed: return "Hidden"
        case .running: return "Checks running"
        case .failed: return "Checks failed"
        case .partial: return "Evidence partial"
        case .verified: return "Exact change verified"
        case .stale: return "Evidence stale"
        }
    }
}

public struct VerificationSnapshot: Sendable, Equatable {
    public var state: VerificationState
    public var projectRoot: String?
    public var changeSet: ChangeSet?
    public var loadedProfile: LoadedVerificationProfile?
    public var record: VerificationRecord?
    public var receipts: [CheckReceipt]
    public var activeCheckName: String?
    public var outputExcerpt: String?
    public var message: String?
    public var sampledAt: Date

    public init(
        state: VerificationState = .unavailable,
        projectRoot: String? = nil,
        changeSet: ChangeSet? = nil,
        loadedProfile: LoadedVerificationProfile? = nil,
        record: VerificationRecord? = nil,
        receipts: [CheckReceipt] = [],
        activeCheckName: String? = nil,
        outputExcerpt: String? = nil,
        message: String? = nil,
        sampledAt: Date = Date()
    ) {
        self.state = state
        self.projectRoot = projectRoot
        self.changeSet = changeSet
        self.loadedProfile = loadedProfile
        self.record = record
        self.receipts = receipts
        self.activeCheckName = activeCheckName
        self.outputExcerpt = outputExcerpt
        self.message = message
        self.sampledAt = sampledAt
    }

    public static let unavailable = VerificationSnapshot()

    public var summary: String {
        if let message, state == .unavailable { return message }
        switch state {
        case .unavailable: return state.label
        case .unconfigured: return "Add .tilde/verify.json"
        case .untrusted:
            let count = loadedProfile?.profile.checks.count ?? 0
            return "Review \(count) command\(count == 1 ? "" : "s")"
        case .missing:
            let count = loadedProfile?.profile.checks.filter(\.required).count ?? 0
            return "\(count) required check\(count == 1 ? "" : "s") missing"
        case .dismissed: return "Hidden until this change moves"
        case .running: return activeCheckName.map { "Running \($0)…" } ?? state.label
        case .failed:
            return receipts.first(where: { $0.outcome == .failed || $0.outcome == .timedOut })?
                .checkName.appending(" failed") ?? state.label
        case .partial: return "Some required evidence is missing"
        case .verified:
            let count = receipts.filter { $0.required && $0.outcome == .passed }.count
            return "\(count) check\(count == 1 ? "" : "s") passed · exact change"
        case .stale: return "Change moved after checks"
        }
    }
}

public enum VerificationError: Error, LocalizedError, Sendable, Equatable {
    case invalidProfile(String)
    case git(String)
    case profileNotTrusted
    case runInProgress
    case profileChanged
    case unableToLaunch(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProfile(let message): return message
        case .git(let message): return message
        case .profileNotTrusted: return "Review and trust this verification profile before running it"
        case .runInProgress: return "Verification is already running"
        case .profileChanged: return "Verification commands changed since review; review them again before running"
        case .unableToLaunch(let message): return message
        }
    }
}
