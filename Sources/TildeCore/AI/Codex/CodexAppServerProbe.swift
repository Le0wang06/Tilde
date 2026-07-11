@preconcurrency import Foundation

public actor CodexAppServerProbe: MetricProvider {
    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func fetchSnapshot() async throws -> CodexDiagnosticSnapshot {
        try Task.checkCancellation()
        let environment = self.environment
        return try await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try Self.runProbe(environment: environment)
        }.value
    }

    private static func runProbe(environment: [String: String]) throws -> CodexDiagnosticSnapshot {
        let executablePath = try commandOutput(executable: "/usr/bin/which", arguments: ["codex"], environment: environment)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !executablePath.isEmpty else { throw MetricError.executableNotFound("Codex") }

        let version = try commandOutput(executable: executablePath, arguments: ["--version"], environment: environment)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        try process.run()
        let requests: [[String: Any]] = [
            [
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": ["name": "tilde", "title": "Tilde", "version": "0.1.0"],
                    "capabilities": ["experimentalApi": false],
                ],
            ],
            ["method": "initialized", "params": [:]],
            ["id": 2, "method": "account/read", "params": ["refreshToken": false]],
            ["id": 3, "method": "account/rateLimits/read", "params": NSNull()],
            ["id": 4, "method": "account/usage/read", "params": NSNull()],
            ["id": 5, "method": "thread/list", "params": ["limit": 100, "archived": false, "useStateDbOnly": true]],
        ]

        for request in requests {
            let data = try JSONSerialization.data(withJSONObject: request)
            input.fileHandleForWriting.write(data)
            input.fileHandleForWriting.write(Data([0x0A]))
        }
        try input.fileHandleForWriting.close()

        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MetricError.invalidResponse(message.isEmpty ? "Codex App Server exited with status \(process.terminationStatus)" : message)
        }

        return try parseResponses(
            String(decoding: stdout, as: UTF8.self),
            executablePath: executablePath,
            version: version
        )
    }

    private static func parseResponses(
        _ output: String,
        executablePath: String,
        version: String
    ) throws -> CodexDiagnosticSnapshot {
        var responses: [Int: [String: Any]] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? Int else { continue }
            responses[id] = object
        }

        if let initializationError = responses[1]?["error"] as? [String: Any] {
            throw MetricError.invalidResponse(initializationError["message"] as? String ?? "Initialization failed")
        }
        guard responses[1]?["result"] != nil else {
            throw MetricError.invalidResponse("Codex App Server did not acknowledge initialization")
        }

        let accountResult = resultDictionary(responses[2])
        let account = accountResult?["account"] as? [String: Any]
        let authenticated = account != nil

        let limitsResult = resultDictionary(responses[3])
        let limits = limitsResult?["rateLimits"] as? [String: Any]
        let primary = parseWindow(limits?["primary"] as? [String: Any])
        let secondary = parseWindow(limits?["secondary"] as? [String: Any])

        let usageResult = resultDictionary(responses[4])
        let summary = usageResult?["summary"] as? [String: Any]
        let dailyBuckets = usageResult?["dailyUsageBuckets"] as? [[String: Any]]
        let today = localDateString()
        let tokensToday = dailyBuckets?.first(where: { ($0["startDate"] as? String)?.prefix(10) == today })?["tokens"] as? Int

        let threadResult = resultDictionary(responses[5])
        let threads = threadResult?["data"] as? [[String: Any]]

        var notes: [String] = []
        if responses[3]?["error"] != nil { notes.append("Codex rate limits are unavailable for this account") }
        if responses[4]?["error"] != nil { notes.append("Codex token usage is unavailable for this account or CLI version") }
        if responses[5]?["error"] != nil { notes.append("Codex thread inventory is unavailable") }

        return CodexDiagnosticSnapshot(
            executablePath: executablePath,
            version: version,
            isAuthenticated: authenticated,
            accountType: account?["type"] as? String,
            planType: account?["planType"] as? String,
            primaryLimit: primary,
            secondaryLimit: secondary,
            tokensToday: tokensToday,
            lifetimeTokens: summary?["lifetimeTokens"] as? Int,
            threadCount: threads?.count,
            notes: notes
        )
    }

    private static func resultDictionary(_ response: [String: Any]?) -> [String: Any]? {
        response?["result"] as? [String: Any]
    }

    private static func parseWindow(_ dictionary: [String: Any]?) -> CodexRateLimitWindow? {
        guard let dictionary, let usedPercent = dictionary["usedPercent"] as? Int else { return nil }
        let resetsAt = (dictionary["resetsAt"] as? TimeInterval).map(Date.init(timeIntervalSince1970:))
        return CodexRateLimitWindow(
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            durationMinutes: dictionary["windowDurationMins"] as? Int
        )
    }

    private static func localDateString() -> Substring {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return Substring(formatter.string(from: Date()))
    }

    private static func commandOutput(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
            throw MetricError.invalidResponse(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: data, as: UTF8.self)
    }
}
