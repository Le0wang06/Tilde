import Foundation

public actor HerdrAgentProvider {
    private let executablePath: String?

    public init(executablePath: String? = HerdrAgentProvider.locateExecutable()) {
        self.executablePath = executablePath
    }

    public func snapshot() -> AgentAttentionSnapshot {
        guard let executablePath else {
            return AgentAttentionSnapshot(
                providerAvailable: false,
                unavailableReason: "Herdr executable was not found"
            )
        }

        let result = Self.run(executablePath, arguments: ["agent", "list"])
        guard result.status == 0 else {
            let reason = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentAttentionSnapshot(
                providerAvailable: false,
                unavailableReason: reason.isEmpty ? "Herdr server is unavailable" : reason
            )
        }

        do {
            return try Self.parseAgentList(Data(result.output.utf8))
        } catch {
            return AgentAttentionSnapshot(
                providerAvailable: false,
                unavailableReason: "Herdr returned an unreadable agent list"
            )
        }
    }

    @discardableResult
    public func focusAgent(terminalID: String) -> Bool {
        guard let executablePath else { return false }
        return Self.run(executablePath, arguments: ["agent", "focus", terminalID]).status == 0
    }

    public static func parseAgentList(_ data: Data) throws -> AgentAttentionSnapshot {
        let response = try JSONDecoder().decode(AgentListResponse.self, from: data)
        let agents = response.result.agents.map { raw -> AgentAttentionItem in
            let cwd = raw.foregroundCwd ?? raw.cwd
            let root = gitValue(["rev-parse", "--show-toplevel"], cwd: cwd)
            let branch = root.flatMap { gitValue(["rev-parse", "--abbrev-ref", "HEAD"], cwd: $0) }
            let projectName = root.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? URL(fileURLWithPath: cwd).lastPathComponent
            return AgentAttentionItem(
                id: raw.terminalId,
                terminalID: raw.terminalId,
                paneID: raw.paneId,
                workspaceID: raw.workspaceId,
                agent: raw.agent,
                state: AgentAttentionState(rawValue: raw.agentStatus) ?? .unknown,
                cwd: cwd,
                projectRoot: root,
                projectName: projectName.isEmpty ? "Unknown project" : projectName,
                branch: branch,
                focused: raw.focused
            )
        }

        return AgentAttentionSnapshot(
            agents: agents,
            providerAvailable: true
        )
    }

    public static func locateExecutable(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let fileManager = FileManager.default
        let explicit = [
            environment["HERDR_BIN_PATH"],
            environment["HOME"].map { "\($0)/.local/bin/herdr" },
            "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr",
        ].compactMap { $0 }
        if let match = explicit.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return match
        }

        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(directory)/herdr"
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func gitValue(_ arguments: [String], cwd: String) -> String? {
        let result = run("/usr/bin/git", arguments: arguments, cwd: cwd)
        guard result.status == 0 else { return nil }
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func run(_ executable: String, arguments: [String], cwd: String? = nil) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        let outputData: Data
        do {
            try process.run()
            outputData = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
        } catch {
            return CommandResult(status: -1, output: "", error: error.localizedDescription)
        }
        return CommandResult(
            status: process.terminationStatus,
            output: String(decoding: outputData, as: UTF8.self),
            error: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}

private struct AgentListResponse: Decodable {
    let result: AgentListResult
}

private struct AgentListResult: Decodable {
    let agents: [RawHerdrAgent]
}

private struct RawHerdrAgent: Decodable {
    let agent: String
    let agentStatus: String
    let cwd: String
    let focused: Bool
    let foregroundCwd: String?
    let paneId: String?
    let terminalId: String
    let workspaceId: String?

    enum CodingKeys: String, CodingKey {
        case agent
        case agentStatus = "agent_status"
        case cwd
        case focused
        case foregroundCwd = "foreground_cwd"
        case paneId = "pane_id"
        case terminalId = "terminal_id"
        case workspaceId = "workspace_id"
    }
}

private struct CommandResult {
    let status: Int32
    let output: String
    let error: String
}
