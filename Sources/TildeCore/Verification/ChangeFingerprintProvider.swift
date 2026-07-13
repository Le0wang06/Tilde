import Foundation

public struct ChangeFingerprintProvider: Sendable {
    public init() {}

    public func snapshot(
        rootPath: String,
        profileHash: String,
        configuredBase: String?
    ) throws -> ChangeSet {
        let root = try gitString(["rev-parse", "--show-toplevel"], in: rootPath)
        let canonicalRoot = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
        let remote = try? gitString(["config", "--get", "remote.origin.url"], in: canonicalRoot)
        let commonGitDirectory = try gitString(["rev-parse", "--git-common-dir"], in: canonicalRoot)
        let canonicalGitDirectory = URL(
            fileURLWithPath: commonGitDirectory,
            relativeTo: URL(fileURLWithPath: canonicalRoot, isDirectory: true)
        ).standardizedFileURL.path
        let repositoryIdentity = remote?.isEmpty == false ? remote! : canonicalGitDirectory
        let repositoryID = VerificationHash.sha256(repositoryIdentity)
        let worktreeID = VerificationHash.sha256("\(repositoryID):\(canonicalRoot)")

        // Git does not expose an atomic worktree snapshot. Two identical full captures prevent
        // a receipt from being bound to a mixture of states while files are actively changing.
        for _ in 0..<3 {
            let first = try capture(
                root: canonicalRoot,
                profileHash: profileHash,
                configuredBase: configuredBase
            )
            let second = try capture(
                root: canonicalRoot,
                profileHash: profileHash,
                configuredBase: configuredBase
            )
            guard first == second else { continue }

            return ChangeSet(
                repositoryID: repositoryID,
                worktreeID: worktreeID,
                worktreePath: canonicalRoot,
                baseRef: second.baseRef,
                baseOID: second.baseOID,
                mergeBaseOID: second.mergeBaseOID,
                headOID: second.headOID,
                changedFiles: second.changedFiles,
                fingerprint: ChangeFingerprint(value: VerificationHash.sha256([
                    "repository:\(repositoryID)",
                    "worktree:\(worktreeID)",
                    "base-ref:\(second.baseRef)",
                    "base-oid:\(second.baseOID)",
                    "merge-base:\(second.mergeBaseOID)",
                    "head:\(second.headOID)",
                    "staged:\(second.stagedDiffHash)",
                    "unstaged:\(second.unstagedDiffHash)",
                    "untracked:\(second.untrackedHash)",
                    "submodules:\(second.submodulesHash)",
                    "profile:\(profileHash)",
                ].joined(separator: "\n")))
            )
        }
        throw VerificationError.git("Worktree changed while computing its fingerprint; retry when writes settle")
    }

    private func capture(
        root: String,
        profileHash: String,
        configuredBase: String?
    ) throws -> FingerprintCapture {
        let headOID = try gitString(["rev-parse", "HEAD"], in: root)
        let baseRef = try resolveBase(configuredBase, in: root)
        let baseOID = try gitString(["rev-parse", "--verify", "\(baseRef)^{commit}"], in: root)
        let mergeBaseOID = try gitString(["merge-base", "HEAD", baseRef], in: root)
        let stagedDiffHash = VerificationHash.sha256(
            try gitData(["diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv", "HEAD"], in: root)
        )
        let unstagedDiffHash = VerificationHash.sha256(
            try gitData(["diff", "--binary", "--no-ext-diff", "--no-textconv"], in: root)
        )
        let untrackedPaths = nullSeparatedPaths(
            try gitData(["ls-files", "--others", "--exclude-standard", "-z"], in: root)
        ).sorted()
        let untrackedHash = try hashUntracked(paths: untrackedPaths, root: root)
        let submodulesHash = try hashSubmodules(in: root, visited: [root])
        let trackedPaths = nullSeparatedPaths(
            try gitData(["diff", "--name-only", "--no-ext-diff", "--no-textconv", "-z", mergeBaseOID], in: root)
        )

        return FingerprintCapture(
            baseRef: baseRef,
            baseOID: baseOID,
            mergeBaseOID: mergeBaseOID,
            headOID: headOID,
            stagedDiffHash: stagedDiffHash,
            unstagedDiffHash: unstagedDiffHash,
            untrackedHash: untrackedHash,
            submodulesHash: submodulesHash,
            changedFiles: Set(trackedPaths + untrackedPaths).count,
            profileHash: profileHash
        )
    }

    private func hashSubmodules(in root: String, visited: Set<String>) throws -> String {
        let index = try gitData(["ls-files", "--stage", "-z"], in: root)
        let gitlinks = String(decoding: index, as: UTF8.self)
            .split(separator: "\0")
            .compactMap { entry -> String? in
                guard entry.hasPrefix("160000 "),
                      let tab = entry.firstIndex(of: "\t") else { return nil }
                return String(entry[entry.index(after: tab)...])
            }
            .sorted()

        var entries: [String] = []
        for path in gitlinks {
            let candidate = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent(path, isDirectory: true)
                .standardizedFileURL.path
            guard gitSucceeds(["rev-parse", "--is-inside-work-tree"], in: candidate) else {
                entries.append("\(path)\u{1f}unavailable")
                continue
            }
            let childRoot = try gitString(["rev-parse", "--show-toplevel"], in: candidate)
            guard !visited.contains(childRoot) else {
                entries.append("\(path)\u{1f}cycle")
                continue
            }
            let childHead = try gitString(["rev-parse", "HEAD"], in: childRoot)
            let staged = VerificationHash.sha256(
                try gitData(["diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv", "HEAD"], in: childRoot)
            )
            let unstaged = VerificationHash.sha256(
                try gitData(["diff", "--binary", "--no-ext-diff", "--no-textconv"], in: childRoot)
            )
            let untrackedPaths = nullSeparatedPaths(
                try gitData(["ls-files", "--others", "--exclude-standard", "-z"], in: childRoot)
            ).sorted()
            let untracked = try hashUntracked(paths: untrackedPaths, root: childRoot)
            let nested = try hashSubmodules(in: childRoot, visited: visited.union([childRoot]))
            entries.append([
                path,
                childHead,
                staged,
                unstaged,
                untracked,
                nested,
            ].joined(separator: "\u{1f}"))
        }
        return VerificationHash.sha256(entries.joined(separator: "\n"))
    }

    private func hashUntracked(paths: [String], root: String) throws -> String {
        var entries: [String] = []
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        for path in paths {
            let url = rootURL.appendingPathComponent(path).standardizedFileURL
            guard url.path == rootURL.path || url.path.hasPrefix(rootURL.path + "/") else {
                throw VerificationError.git("Untracked path escaped the worktree: \(path)")
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let kind: String
            let contentHash: String
            if values.isSymbolicLink == true {
                kind = "symlink"
                contentHash = VerificationHash.sha256(
                    try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                )
            } else if values.isRegularFile == true {
                kind = "file"
                contentHash = try VerificationHash.sha256(fileAt: url)
            } else {
                kind = "other"
                contentHash = VerificationHash.sha256("")
            }
            entries.append([
                path,
                kind,
                String(permissions),
                String(values.fileSize ?? 0),
                contentHash,
            ].joined(separator: "\u{1f}"))
        }
        return VerificationHash.sha256(entries.joined(separator: "\n"))
    }

    private func resolveBase(_ configuredBase: String?, in root: String) throws -> String {
        if let configuredBase,
           !configuredBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try gitString(["rev-parse", "--verify", "\(configuredBase)^{commit}"], in: root)
            return configuredBase
        }

        var candidates: [String] = []
        if let remoteHead = try? gitString(
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
            in: root
        ) {
            candidates.append(remoteHead)
        }
        candidates.append(contentsOf: ["origin/main", "origin/master", "main", "master"])
        if let localBase = localAncestorBase(in: root) { candidates.append(localBase) }

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            if (try? gitString(["rev-parse", "--verify", "\(candidate)^{commit}"], in: root)) != nil {
                return candidate
            }
        }
        return "HEAD"
    }

    private func localAncestorBase(in root: String) -> String? {
        guard let current = try? gitString(["rev-parse", "--abbrev-ref", "HEAD"], in: root),
              current != "HEAD",
              let rawBranches = try? gitString(
                ["for-each-ref", "--format=%(refname:short)", "refs/heads"],
                in: root
              ) else { return nil }
        return rawBranches.split(separator: "\n").map(String.init)
            .filter { $0 != current && gitSucceeds(["merge-base", "--is-ancestor", $0, "HEAD"], in: root) }
            .compactMap { branch -> (String, Int)? in
                guard let raw = try? gitString(["rev-list", "--count", "\(branch)..HEAD"], in: root),
                      let count = Int(raw) else { return nil }
                return (branch, count)
            }
            .min { $0.1 < $1.1 }?.0
    }

    private func nullSeparatedPaths(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
    }

    private func gitSucceeds(_ arguments: [String], in root: String) -> Bool {
        (try? gitData(arguments, in: root)) != nil
    }

    private func gitString(_ arguments: [String], in root: String) throws -> String {
        String(decoding: try gitData(arguments, in: root), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gitData(_ arguments: [String], in root: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw VerificationError.git("Unable to run git: \(error.localizedDescription)")
        }
        let errorReader = SynchronousPipeReader(handle: errors.fileHandleForReading)
        errorReader.start()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let errorData = errorReader.finish()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw VerificationError.git(message.isEmpty ? "Git command failed" : message)
        }
        return data
    }
}

private struct FingerprintCapture: Equatable {
    let baseRef: String
    let baseOID: String
    let mergeBaseOID: String
    let headOID: String
    let stagedDiffHash: String
    let unstagedDiffHash: String
    let untrackedHash: String
    let submodulesHash: String
    let changedFiles: Int
    let profileHash: String
}

private final class SynchronousPipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var captured = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func start() {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            let data = handle.readDataToEndOfFile()
            lock.withLock { captured = data }
            group.leave()
        }
    }

    func finish() -> Data {
        group.wait()
        return lock.withLock { captured }
    }
}
