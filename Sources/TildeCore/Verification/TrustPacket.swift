import Foundation

public enum TrustPacketState: String, Sendable, Equatable {
    case unavailable
    case verifying
    case needsVerification
    case ready

    public var label: String {
        switch self {
        case .unavailable: return "No project"
        case .verifying: return "Verifying"
        case .needsVerification: return "Needs verification"
        case .ready: return "Evidence ready"
        }
    }
}

public enum TrustRiskKind: String, Codable, Sendable, Equatable {
    case largeChange
    case sensitiveFiles
    case buildUnknown
    case buildFailed
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
    public var risks: [TrustRisk]
    public var sampledAt: Date

    public init(
        state: TrustPacketState = .unavailable,
        projectRoot: String? = nil,
        changedFiles: Int = 0,
        additions: Int = 0,
        deletions: Int = 0,
        risks: [TrustRisk] = [],
        sampledAt: Date = Date()
    ) {
        self.state = state
        self.projectRoot = projectRoot
        self.changedFiles = changedFiles
        self.additions = additions
        self.deletions = deletions
        self.risks = risks
        self.sampledAt = sampledAt
    }

    public static let unavailable = TrustPacketSnapshot()

    public var summary: String {
        guard projectRoot != nil else { return state.label }
        if changedFiles == 0 { return "Clean · no local changes" }
        let delta = "+\(additions) −\(deletions)"
        if risks.isEmpty { return "\(changedFiles) files · \(delta)" }
        return "\(risks.count) check\(risks.count == 1 ? "" : "s") · \(changedFiles) files"
    }
}

public actor TrustPacketProvider {
    public init() {}

    public func snapshot(
        rootPath: String?,
        build: BuildPulseSnapshot,
        ciStatus: ProjectCIStatus,
        behind: Int?
    ) -> TrustPacketSnapshot {
        guard let rootPath else { return .unavailable }

        let statusLines = Self.git(["status", "--porcelain"], in: rootPath)?
            .split(separator: "\n")
            .map(String.init) ?? []
        let numstat = [
            Self.git(["diff", "--numstat"], in: rootPath),
            Self.git(["diff", "--cached", "--numstat"], in: rootPath),
        ].compactMap { $0 }.joined(separator: "\n")
        let delta = Self.parseNumstat(numstat)
        let paths = Set(statusLines.compactMap(Self.pathFromPorcelain))
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
        switch build.phase {
        case .running:
            break
        case .finished where build.lastSucceeded == false:
            risks.append(TrustRisk(kind: .buildFailed, message: "The last observed build failed"))
        case .finished where build.lastSucceeded == true:
            break
        case .idle, .finished:
            if !paths.isEmpty {
                risks.append(TrustRisk(kind: .buildUnknown, message: "No passing build is attached to these changes"))
            }
        }
        switch ciStatus {
        case .failure, .cancelled:
            risks.append(TrustRisk(kind: .ciFailed, message: "The latest CI run did not pass"))
        case .pending:
            risks.append(TrustRisk(kind: .ciPending, message: "CI is still running"))
        case .success, .unknown:
            break
        }
        if let behind, behind > 0 {
            risks.append(TrustRisk(kind: .branchBehind, message: "Branch is \(behind) commit\(behind == 1 ? "" : "s") behind upstream"))
        }

        let state: TrustPacketState
        if build.phase == .running || ciStatus == .pending {
            state = .verifying
        } else if paths.isEmpty || risks.isEmpty {
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
