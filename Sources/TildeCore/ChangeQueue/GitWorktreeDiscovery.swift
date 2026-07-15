import Foundation

public struct GitWorktreeDescriptor: Sendable, Equatable, Identifiable {
    public var id: String { "\(repositoryID)|\(path)" }
    public let repositoryID: String
    public let path: String
    public let headOID: String?
    public let branch: String?
    public let isDetached: Bool
    public let isLocked: Bool
    public let isPrunable: Bool

    public init(
        repositoryID: String,
        path: String,
        headOID: String? = nil,
        branch: String? = nil,
        isDetached: Bool = false,
        isLocked: Bool = false,
        isPrunable: Bool = false
    ) {
        self.repositoryID = repositoryID
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.headOID = headOID
        self.branch = branch
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }
}

public struct GitWorktreeDiscoverySnapshot: Sendable, Equatable {
    public let worktrees: [GitWorktreeDescriptor]
    public let notes: [String]
    public let sampledAt: Date

    public init(
        worktrees: [GitWorktreeDescriptor] = [],
        notes: [String] = [],
        sampledAt: Date = Date()
    ) {
        self.worktrees = worktrees
        self.notes = notes
        self.sampledAt = sampledAt
    }
}

/// Read-only discovery of every linked worktree for repositories observed through agents or editors.
public actor GitWorktreeDiscovery {
    public init() {}

    public func snapshot(seedPaths: [String]) -> GitWorktreeDiscoverySnapshot {
        var repositories = Set<String>()
        var worktrees: [String: GitWorktreeDescriptor] = [:]
        var notes: [String] = []

        for seed in seedPaths where !seed.isEmpty {
            let seedURL = URL(fileURLWithPath: seed).standardizedFileURL
            guard FileManager.default.fileExists(atPath: seedURL.path) else {
                notes.append("Worktree path is no longer available: \(seedURL.path)")
                continue
            }
            guard let root = Self.git(["rev-parse", "--show-toplevel"], in: seedURL.path)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !root.isEmpty else {
                notes.append("No Git repository found for \(seedURL.path)")
                continue
            }
            guard let commonDirectory = Self.commonDirectory(in: root) else {
                notes.append("Git common directory is unavailable for \(root)")
                continue
            }
            guard repositories.insert(commonDirectory).inserted else { continue }
            guard let output = Self.git(["worktree", "list", "--porcelain"], in: root) else {
                notes.append("Git worktree inventory is unavailable for \(root)")
                continue
            }
            for descriptor in Self.parsePorcelain(output, repositoryID: commonDirectory) {
                worktrees[descriptor.id] = descriptor
            }
        }

        return GitWorktreeDiscoverySnapshot(
            worktrees: worktrees.values.sorted {
                if $0.repositoryID != $1.repositoryID { return $0.repositoryID < $1.repositoryID }
                return $0.path < $1.path
            },
            notes: Array(Set(notes)).sorted()
        )
    }

    static func parsePorcelain(_ output: String, repositoryID: String) -> [GitWorktreeDescriptor] {
        struct Pending {
            var path: String?
            var headOID: String?
            var branch: String?
            var detached = false
            var locked = false
            var prunable = false
        }

        func descriptor(_ pending: Pending) -> GitWorktreeDescriptor? {
            guard let path = pending.path else { return nil }
            return GitWorktreeDescriptor(
                repositoryID: repositoryID,
                path: path,
                headOID: pending.headOID,
                branch: pending.branch,
                isDetached: pending.detached,
                isLocked: pending.locked,
                isPrunable: pending.prunable
            )
        }

        var result: [GitWorktreeDescriptor] = []
        var pending = Pending()
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                if let item = descriptor(pending) { result.append(item) }
                pending = Pending()
            } else if line.hasPrefix("worktree ") {
                pending.path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                pending.headOID = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                pending.branch = String(line.dropFirst("branch ".count))
                    .replacingOccurrences(of: "refs/heads/", with: "")
            } else if line == "detached" {
                pending.detached = true
            } else if line == "locked" || line.hasPrefix("locked ") {
                pending.locked = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                pending.prunable = true
            }
        }
        if let item = descriptor(pending), result.last?.id != item.id { result.append(item) }
        return result
    }

    private static func commonDirectory(in root: String) -> String? {
        guard let raw = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: root)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw).standardizedFileURL.path
    }

    private static func git(_ arguments: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }
}
