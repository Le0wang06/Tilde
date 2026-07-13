import Foundation

public enum TrustPacketState: String, Sendable, Equatable {
    case unavailable
    case verifying
    case needsVerification
    case ready

    public var label: String {
        switch self {
        case .unavailable: return "No project"
        case .verifying: return "Matching checks running"
        case .needsVerification: return "Review needed"
        case .ready: return "No known warnings"
        }
    }
}

public enum TrustRiskKind: String, Codable, Sendable, Equatable {
    case largeChange
    case sensitiveFiles
    case buildUnknown
    case buildFailed
    case verificationMissing
    case verificationFailed
    case verificationStale
    case ciUnknown
    case ciPending
    case ciFailed
    case branchBehind
}

public struct TrustRisk: Codable, Sendable, Equatable, Identifiable {
    public var id: TrustRiskKind { kind }
    public let kind: TrustRiskKind
    public let message: String

    public init(kind: TrustRiskKind, message: String) {
        self.kind = kind
        self.message = message
    }
}

public struct TrustPacketSnapshot: Sendable, Equatable {
    public var state: TrustPacketState
    public var projectRoot: String?
    public var changedFiles: Int
    public var additions: Int
    public var deletions: Int
    public var untrackedFiles: Int
    public var comparisonBase: String?
    public var risks: [TrustRisk]
    public var sampledAt: Date

    public init(
        state: TrustPacketState = .unavailable,
        projectRoot: String? = nil,
        changedFiles: Int = 0,
        additions: Int = 0,
        deletions: Int = 0,
        untrackedFiles: Int = 0,
        comparisonBase: String? = nil,
        risks: [TrustRisk] = [],
        sampledAt: Date = Date()
    ) {
        self.state = state
        self.projectRoot = projectRoot
        self.changedFiles = changedFiles
        self.additions = additions
        self.deletions = deletions
        self.untrackedFiles = untrackedFiles
        self.comparisonBase = comparisonBase
        self.risks = risks
        self.sampledAt = sampledAt
    }

    public static let unavailable = TrustPacketSnapshot()

    public var summary: String {
        guard projectRoot != nil else { return state.label }
        if changedFiles == 0 {
            if risks.isEmpty { return "No change detected" }
            return "\(risks.count) check\(risks.count == 1 ? "" : "s") needed"
        }
        let scope = comparisonBase.map { " vs \($0)" } ?? ""
        let delta = "+\(additions) −\(deletions)"
        let untracked = untrackedFiles > 0 ? " · \(untrackedFiles) untracked" : ""
        if risks.isEmpty { return "\(changedFiles) files\(scope) · \(delta)\(untracked)" }
        return "\(risks.count) check\(risks.count == 1 ? "" : "s") · \(changedFiles) files\(scope)"
    }
}

public actor TrustPacketProvider {
    public init() {}

    public func snapshot(
        rootPath: String?,
        build: BuildPulseSnapshot,
        ciStatus: ProjectCIStatus,
        behind: Int?,
        verification: VerificationSnapshot = .unavailable
    ) -> TrustPacketSnapshot {
        guard let rootPath else { return .unavailable }

        let statusLines = Self.git(["status", "--porcelain"], in: rootPath)?
            .split(separator: "\n")
            .map(String.init) ?? []
        let comparison = Self.comparisonBase(in: rootPath)
        let numstat: String
        let trackedPaths: [String]
        if let startOID = comparison?.startOID {
            numstat = Self.git(["diff", "--numstat", startOID], in: rootPath) ?? ""
            trackedPaths = Self.nullSeparatedPaths(
                Self.git(["diff", "--name-only", "-z", startOID], in: rootPath) ?? ""
            )
        } else {
            numstat = [
                Self.git(["diff", "--numstat"], in: rootPath),
                Self.git(["diff", "--cached", "--numstat"], in: rootPath),
            ].compactMap { $0 }.joined(separator: "\n")
            trackedPaths = statusLines.compactMap(Self.pathFromPorcelain)
        }
        let untrackedPaths = Self.nullSeparatedPaths(
            Self.git(["ls-files", "--others", "--exclude-standard", "-z"], in: rootPath) ?? ""
        )
        let delta = Self.parseNumstat(numstat)
        let paths = Set(trackedPaths + untrackedPaths)
        let hasWorkingChanges = !statusLines.isEmpty
        var risks: [TrustRisk] = []

        if delta.additions + delta.deletions > 500 || paths.count > 20 {
            risks.append(TrustRisk(kind: .largeChange, message: "Large change deserves a deliberate review"))
        }
        let sensitive = paths.filter(Self.isSensitivePath)
        if !sensitive.isEmpty {
            risks.append(TrustRisk(
                kind: .sensitiveFiles,
                message: "Sensitive configuration or dependency files changed"
            ))
        }
        if !paths.isEmpty {
            switch verification.state {
            case .verified:
                break
            case .running:
                break
            case .failed:
                risks.append(TrustRisk(
                    kind: .verificationFailed,
                    message: "Required checks failed for this exact change"
                ))
            case .stale:
                risks.append(TrustRisk(
                    kind: .verificationStale,
                    message: "Passing evidence belongs to an earlier change fingerprint"
                ))
            case .unconfigured:
                risks.append(TrustRisk(
                    kind: .verificationMissing,
                    message: "No repository verification profile is configured"
                ))
            case .untrusted:
                risks.append(TrustRisk(
                    kind: .verificationMissing,
                    message: "Verification commands have not been reviewed and trusted"
                ))
            case .missing, .partial:
                risks.append(TrustRisk(
                    kind: .verificationMissing,
                    message: "Required checks are missing for this exact change"
                ))
            case .unavailable:
                appendObservedBuildRisk(build, to: &risks)
            }
        }
        if !paths.isEmpty {
            switch ciStatus {
            case .failure, .cancelled:
                risks.append(TrustRisk(kind: .ciFailed, message: "CI for the current commit did not pass"))
            case .pending where hasWorkingChanges:
                risks.append(TrustRisk(
                    kind: .ciUnknown,
                    message: "CI is running for HEAD; local changes are not included"
                ))
            case .pending:
                risks.append(TrustRisk(kind: .ciPending, message: "CI for the current commit is still running"))
            case .success where hasWorkingChanges:
                risks.append(TrustRisk(
                    kind: .ciUnknown,
                    message: "CI passed for HEAD; local changes are not included"
                ))
            case .unknown:
                risks.append(TrustRisk(kind: .ciUnknown, message: "No CI result matches the current commit"))
            case .success:
                break
            }
        }
        if let behind, behind > 0 {
            risks.append(TrustRisk(kind: .branchBehind, message: "Branch is \(behind) commit\(behind == 1 ? "" : "s") behind upstream"))
        }

        let state: TrustPacketState
        if verification.state == .running {
            state = .verifying
        } else if risks.isEmpty {
            state = .ready
        } else {
            state = .needsVerification
        }

        return TrustPacketSnapshot(
            state: state,
            projectRoot: rootPath,
            changedFiles: paths.count,
            additions: delta.additions,
            deletions: delta.deletions,
            untrackedFiles: untrackedPaths.count,
            comparisonBase: comparison?.label,
            risks: risks
        )
    }

    public static func parseNumstat(_ text: String) -> (additions: Int, deletions: Int) {
        var additions = 0
        var deletions = 0
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            additions += Int(fields[0]) ?? 0
            deletions += Int(fields[1]) ?? 0
        }
        return (additions, deletions)
    }

    public static func isSensitivePath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix("package.swift")
            || lower.contains("package-lock")
            || lower.contains("pnpm-lock")
            || lower.contains("yarn.lock")
            || lower.contains("cargo.lock")
            || lower.contains("podfile")
            || lower.contains("entitlements")
            || lower.contains("info.plist")
            || lower.contains("migration")
            || lower.contains("auth")
            || lower.contains("permission")
            || lower.contains(".github/workflows")
            || lower.contains("deploy")
    }

    private func appendObservedBuildRisk(
        _ build: BuildPulseSnapshot,
        to risks: inout [TrustRisk]
    ) {
        switch build.phase {
        case .finished where build.lastSucceeded == false:
            risks.append(TrustRisk(kind: .buildFailed, message: "The last observed build failed"))
        case .finished where build.lastSucceeded == true:
            risks.append(TrustRisk(
                kind: .buildUnknown,
                message: "A build passed, but it is not bound to this exact change"
            ))
        case .running:
            risks.append(TrustRisk(
                kind: .buildUnknown,
                message: "A build is running, but it is not bound to this exact change"
            ))
        case .idle, .finished:
            risks.append(TrustRisk(kind: .buildUnknown, message: "No build result is bound to this exact change"))
        }
    }

    static func nullSeparatedPaths(_ text: String) -> [String] {
        text.split(separator: "\0").map(String.init)
    }

    private static func comparisonBase(in root: String) -> (label: String, startOID: String)? {
        var candidates: [String] = []
        if let remoteHead = git(
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
            in: root
        )?.trimmingCharacters(in: .whitespacesAndNewlines), !remoteHead.isEmpty {
            candidates.append(remoteHead)
        }
        candidates.append(contentsOf: ["origin/main", "origin/master", "main", "master"])
        if let localBase = localAncestorBase(in: root) {
            candidates.append(localBase)
        }

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            guard git(["rev-parse", "--verify", "\(candidate)^{commit}"], in: root) != nil,
                  let mergeBase = git(["merge-base", "HEAD", candidate], in: root)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !mergeBase.isEmpty else { continue }
            return (candidate.replacingOccurrences(of: "origin/", with: ""), mergeBase)
        }

        guard let head = git(["rev-parse", "--verify", "HEAD^{commit}"], in: root)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty else { return nil }
        return ("HEAD", head)
    }

    /// Local-only repositories do not record a default branch. Prefer the
    /// closest local branch that is an ancestor of HEAD instead of silently
    /// comparing a feature branch with itself.
    private static func localAncestorBase(in root: String) -> String? {
        guard let current = git(["rev-parse", "--abbrev-ref", "HEAD"], in: root)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !current.isEmpty,
              current != "HEAD" else { return nil }
        let branches = git(
            ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
            in: root
        )?.split(separator: "\n").map(String.init) ?? []

        return branches
            .filter { $0 != current && git(["merge-base", "--is-ancestor", $0, "HEAD"], in: root) != nil }
            .compactMap { branch -> (branch: String, distance: Int)? in
                guard let raw = git(["rev-list", "--count", "\(branch)..HEAD"], in: root)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      let distance = Int(raw) else { return nil }
                return (branch, distance)
            }
            .min { $0.distance < $1.distance }?
            .branch
    }

    private static func pathFromPorcelain(_ line: String) -> String? {
        guard line.count > 3 else { return nil }
        let value = String(line.dropFirst(3))
        if let rename = value.range(of: " -> ") {
            return String(value[rename.upperBound...])
        }
        return value
    }

    private static func git(_ arguments: [String], in root: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        let data: Data
        do {
            try process.run()
            data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
