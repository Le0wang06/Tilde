import Foundation

public enum CodexExecutableLocator {
    public static func locate(environment: [String: String]) -> String? {
        candidatePaths(environment: environment).first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    public static func candidatePaths(environment: [String: String]) -> [String] {
        var candidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/codex" }

        if let home = environment["HOME"], !home.isEmpty {
            candidates.append(contentsOf: [
                "\(home)/.local/bin/codex",
                "\(home)/.npm-global/bin/codex",
            ])
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ])

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }
}
