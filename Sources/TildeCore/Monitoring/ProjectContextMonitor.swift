import Foundation

public enum ProjectCIStatus: String, Sendable, Equatable {
    case unknown
    case pending
    case success
    case failure
    case cancelled

    public var label: String {
        switch self {
        case .unknown: return "CI —"
        case .pending: return "CI · running"
        case .success: return "CI · pass"
        case .failure: return "CI · fail"
        case .cancelled: return "CI · cancelled"
        }
    }
}

public struct ProjectContextSnapshot: Sendable, Equatable {
    public var projectName: String?
    public var rootPath: String?
    public var branch: String?
    public var headOID: String?
    public var isDirty: Bool
    public var ahead: Int?
    public var behind: Int?
    public var ciStatus: ProjectCIStatus
    public var ciSummary: String?

    public init(
        projectName: String? = nil,
        rootPath: String? = nil,
        branch: String? = nil,
        headOID: String? = nil,
        isDirty: Bool = false,
        ahead: Int? = nil,
        behind: Int? = nil,
        ciStatus: ProjectCIStatus = .unknown,
        ciSummary: String? = nil
    ) {
        self.projectName = projectName
        self.rootPath = rootPath
        self.branch = branch
        self.headOID = headOID
        self.isDirty = isDirty
        self.ahead = ahead
        self.behind = behind
        self.ciStatus = ciStatus
        self.ciSummary = ciSummary
    }

    public static let empty = ProjectContextSnapshot()

    public var hasProject: Bool { rootPath != nil }

    public var chipText: String {
        guard let branch else { return "No project" }
        var text = branch
        if isDirty { text += "*" }
        if let ahead, ahead > 0 { text += " ↑\(ahead)" }
        if let behind, behind > 0 { text += " ↓\(behind)" }
        return text
    }

    public var detailText: String {
        guard let name = projectName else { return "Open a repo in Cursor, Terminal, or Xcode" }
        var parts = [name]
        if ciStatus != .unknown {
            parts.append(ciStatus.label)
        } else if let ciSummary {
            parts.append(ciSummary)
        }
        return parts.joined(separator: " · ")
    }
}

/// Resolves the active developer project and reads git / optional CI status.
public actor ProjectContextMonitor {
    private var lastCIFetchAt: Date?
    private var cachedCI: (root: String, headOID: String?, status: ProjectCIStatus, summary: String?)?

    public init() {}

    public func snapshot(preferredRoot: String? = nil) async -> ProjectContextSnapshot {
        let preferred = preferredRoot.flatMap(Self.gitRoot(for:))
        guard let root = preferred ?? Self.resolveProjectRoot() else {
            return .empty
        }

        let name = URL(fileURLWithPath: root).lastPathComponent
        let branch = Self.runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: root)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let headOID = Self.runGit(["rev-parse", "HEAD"], in: root)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let porcelain = Self.runGit(["status", "--porcelain"], in: root) ?? ""
        let isDirty = !porcelain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        var ahead: Int?
        var behind: Int?
        if let counts = Self.runGit(
            ["rev-list", "--left-right", "--count", "@{upstream}...HEAD"],
            in: root
        )?.trimmingCharacters(in: .whitespacesAndNewlines) {
            let parts = counts.split(whereSeparator: { $0.isWhitespace })
            if parts.count == 2, let b = Int(parts[0]), let a = Int(parts[1]) {
                behind = b
                ahead = a
            }
        }

        let ci = await refreshCIIfNeeded(root: root, headOID: headOID)
        return ProjectContextSnapshot(
            projectName: name,
            rootPath: root,
            branch: (branch?.isEmpty == false) ? branch : nil,
            headOID: (headOID?.isEmpty == false) ? headOID : nil,
            isDirty: isDirty,
            ahead: ahead,
            behind: behind,
            ciStatus: ci.status,
            ciSummary: ci.summary
        )
    }

    private func refreshCIIfNeeded(root: String, headOID: String?) async -> (status: ProjectCIStatus, summary: String?) {
        if let cached = cachedCI, cached.root == root, cached.headOID == headOID,
           let last = lastCIFetchAt, Date().timeIntervalSince(last) < 45 {
            return (cached.status, cached.summary)
        }

        let result = await Self.fetchCIStatus(in: root, headOID: headOID)
        lastCIFetchAt = Date()
        cachedCI = (root, headOID, result.status, result.summary)
        return result
    }

    private static func resolveProjectRoot() -> String? {
        for path in candidateWorkingDirectories() {
            if let root = gitRoot(for: path) {
                return root
            }
        }
        return nil
    }

    private static func candidateWorkingDirectories() -> [String] {
        var paths: [String] = []

        if let recent = recentCursorWorkspacePath() {
            paths.append(recent)
        }

        for pid in pidsMatching(
            names: ["Cursor", "Code", "Xcode", "Terminal", "iTerm2", "Warp", "Hyper"]
        ) {
            if let cwd = processCWD(pid: pid) {
                paths.append(cwd)
            }
        }

        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private static func pidsMatching(names: [String]) -> [Int32] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "pid=,comm="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        let data: Data
        do {
            try proc.run()
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
        } catch {
            return []
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        var pids: [Int32] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { continue }
            let pidString = trimmed[..<space]
            let comm = String(trimmed[trimmed.index(after: space)...])
            guard let pid = Int32(pidString) else { continue }
            if names.contains(where: { comm.contains($0) }) {
                pids.append(pid)
            }
        }
        return pids
    }

    private static func processCWD(pid: Int32) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        let data: Data
        do {
            try proc.run()
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("n") {
            let path = String(line.dropFirst())
            if path.hasPrefix("/") { return path }
        }
        return nil
    }

    private static func recentCursorWorkspacePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let storage = "\(home)/Library/Application Support/Cursor/User/globalStorage/storage.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: storage)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let windows = json["windowsState"] as? [String: Any],
           let last = windows["lastActiveWindow"] as? [String: Any],
           let folder = last["folder"] as? String,
           let path = fileURLPath(from: folder) {
            return path
        }

        if let backup = json["backupWorkspaces"] as? [String: Any],
           let folders = backup["folders"] as? [[String: Any]],
           let first = folders.first?["folderUri"] as? String,
           let path = fileURLPath(from: first) {
            return path
        }
        return nil
    }

    private static func fileURLPath(from uri: String) -> String? {
        if uri.hasPrefix("file://"), let url = URL(string: uri) {
            return url.path
        }
        if uri.hasPrefix("/") { return uri }
        return nil
    }

    private static func gitRoot(for path: String) -> String? {
        runGit(["rev-parse", "--show-toplevel"], in: path)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runGit(_ args: [String], in directory: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: directory)
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        let data: Data
        do {
            try proc.run()
            data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func fetchCIStatus(
        in root: String,
        headOID: String?
    ) async -> (status: ProjectCIStatus, summary: String?) {
        guard let headOID, !headOID.isEmpty else { return (.unknown, "No current commit") }
        let ghCandidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        guard let gh = ghCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return (.unknown, nil)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: gh)
        proc.arguments = [
            "run", "list",
            "--commit", headOID,
            "--limit", "1",
            "--json", "conclusion,status,name,displayTitle,headBranch,headSha,url",
        ]
        proc.currentDirectoryURL = URL(fileURLWithPath: root)
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        let data: Data
        do {
            try proc.run()
            data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
        } catch {
            return (.unknown, nil)
        }
        guard proc.terminationStatus == 0 else { return (.unknown, nil) }
        return parseCIStatus(data, matchingHead: headOID)
    }

    static func parseCIStatus(
        _ data: Data,
        matchingHead headOID: String
    ) -> (status: ProjectCIStatus, summary: String?) {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = rows.first else {
            return (.unknown, "No CI for current commit")
        }
        guard (first["headSha"] as? String) == headOID else {
            return (.unknown, "No CI for current commit")
        }

        let statusRaw = (first["status"] as? String)?.lowercased() ?? ""
        let conclusion = (first["conclusion"] as? String)?.lowercased() ?? ""
        let title = (first["displayTitle"] as? String) ?? (first["name"] as? String) ?? "CI"

        if statusRaw == "in_progress" || statusRaw == "queued" || statusRaw == "pending" {
            return (.pending, title)
        }
        switch conclusion {
        case "success": return (.success, title)
        case "failure", "timed_out", "startup_failure": return (.failure, title)
        case "cancelled": return (.cancelled, title)
        default: return (.unknown, title)
        }
    }
}
