import Foundation

public enum BuildPulseKind: String, Sendable, Equatable {
    case swiftBuild = "swift build"
    case xcodebuild
    case npm
    case cargo
    case pytest
    case other

    public var label: String {
        switch self {
        case .swiftBuild: return "Swift"
        case .xcodebuild: return "Xcode"
        case .npm: return "npm"
        case .cargo: return "Cargo"
        case .pytest: return "Pytest"
        case .other: return "Build"
        }
    }
}

public enum BuildPulsePhase: String, Sendable, Equatable {
    case idle
    case running
    case finished
}

public struct BuildPulseSnapshot: Sendable, Equatable {
    public var phase: BuildPulsePhase
    public var kind: BuildPulseKind?
    public var commandSummary: String?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var lastDuration: TimeInterval?
    /// Best-effort; usually nil for unmatched CLI processes we don't parent.
    public var lastSucceeded: Bool?

    public init(
        phase: BuildPulsePhase = .idle,
        kind: BuildPulseKind? = nil,
        commandSummary: String? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        lastDuration: TimeInterval? = nil,
        lastSucceeded: Bool? = nil
    ) {
        self.phase = phase
        self.kind = kind
        self.commandSummary = commandSummary
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.lastDuration = lastDuration
        self.lastSucceeded = lastSucceeded
    }

    public var statusText: String {
        switch phase {
        case .idle:
            if let lastDuration {
                let seconds = Int(lastDuration.rounded())
                return "Last \(kind?.label ?? "build") · \(seconds)s"
            }
            return "No recent builds"
        case .running:
            return "\(kind?.label ?? "Build") running…"
        case .finished:
            let seconds = Int((lastDuration ?? 0).rounded())
            if let lastSucceeded {
                return lastSucceeded ? "Passed · \(seconds)s" : "Failed · \(seconds)s"
            }
            return "Finished · \(seconds)s"
        }
    }
}

/// Polls the process table for common developer build/test commands.
public actor BuildPulseMonitor {
    private var activePID: Int32?
    private var activeKind: BuildPulseKind?
    private var activeSummary: String?
    private var startedAt: Date?
    private var lastSnapshot = BuildPulseSnapshot()

    public init() {}

    public func snapshot() -> BuildPulseSnapshot {
        refresh()
        return lastSnapshot
    }

    @discardableResult
    public func refresh() -> BuildPulseSnapshot {
        let matches = Self.scanProcesses()
        let now = Date()

        if let match = matches.first {
            if activePID != match.pid {
                activePID = match.pid
                activeKind = match.kind
                activeSummary = match.summary
                startedAt = now
            }
            let started = startedAt ?? now
            lastSnapshot = BuildPulseSnapshot(
                phase: .running,
                kind: match.kind,
                commandSummary: match.summary,
                startedAt: started,
                finishedAt: nil,
                lastDuration: now.timeIntervalSince(started),
                lastSucceeded: nil
            )
            return lastSnapshot
        }

        if let _ = activePID, let startedAt {
            let duration = now.timeIntervalSince(startedAt)
            lastSnapshot = BuildPulseSnapshot(
                phase: .finished,
                kind: activeKind,
                commandSummary: activeSummary,
                startedAt: startedAt,
                finishedAt: now,
                lastDuration: duration,
                lastSucceeded: nil
            )
            self.activePID = nil
            self.activeKind = nil
            self.activeSummary = nil
            self.startedAt = nil
            // Keep finished state briefly; next idle poll without match stays finished until aged out.
            return lastSnapshot
        }

        // Age finished → idle after 3 minutes of quiet.
        if lastSnapshot.phase == .finished,
           let finishedAt = lastSnapshot.finishedAt,
           now.timeIntervalSince(finishedAt) > 180 {
            lastSnapshot = BuildPulseSnapshot(
                phase: .idle,
                kind: lastSnapshot.kind,
                commandSummary: lastSnapshot.commandSummary,
                startedAt: lastSnapshot.startedAt,
                finishedAt: lastSnapshot.finishedAt,
                lastDuration: lastSnapshot.lastDuration,
                lastSucceeded: lastSnapshot.lastSucceeded
            )
        } else if lastSnapshot.phase != .finished {
            if lastSnapshot.lastDuration == nil {
                lastSnapshot = BuildPulseSnapshot()
            } else if lastSnapshot.phase != .idle {
                lastSnapshot.phase = .idle
            }
        }

        return lastSnapshot
    }

    private struct Match {
        var pid: Int32
        var kind: BuildPulseKind
        var summary: String
    }

    private static func scanProcesses() -> [Match] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var matches: [Match] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { continue }
            let pidString = String(trimmed[..<space])
            let command = String(trimmed[trimmed.index(after: space)...])
            guard let pid = Int32(pidString) else { continue }
            guard let kind = classify(command) else { continue }
            // Skip our own tooling noise.
            if command.contains("tilde-fan") || command.contains("TildeDiagnostics") { continue }
            let summary = String(command.prefix(80))
            matches.append(Match(pid: pid, kind: kind, summary: summary))
        }
        return matches
    }

    private static func classify(_ command: String) -> BuildPulseKind? {
        let lower = command.lowercased()
        if lower.contains("xcodebuild") { return .xcodebuild }
        if lower.contains("swift build") || lower.contains("/swift build") || lower.hasPrefix("swift build") {
            return .swiftBuild
        }
        // `swift-frontend` / driver during build
        if lower.contains("swift-frontend") || lower.contains("swift-driver") { return .swiftBuild }
        if lower.contains("npm test") || lower.contains("npm run test") || lower.contains("npm run build") {
            return .npm
        }
        if lower.contains("cargo test") || lower.contains("cargo build") || lower.contains("cargo check") {
            return .cargo
        }
        if lower.contains("pytest") { return .pytest }
        return nil
    }
}
