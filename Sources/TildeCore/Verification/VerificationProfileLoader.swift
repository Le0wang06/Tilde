import CryptoKit
import Foundation

enum VerificationHash {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ string: String) -> String {
        sha256(Data(string.utf8))
    }

    static func sha256(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 64 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct VerificationProfileLoader: Sendable {
    public init() {}

    public func load(from rootPath: String) throws -> LoadedVerificationProfile? {
        let fileURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent(".tilde/verify.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw VerificationError.invalidProfile(".tilde/verify.json must be a regular, non-symlink file")
        }

        let data = try Data(contentsOf: fileURL)
        let profile: VerificationProfile
        do {
            profile = try JSONDecoder().decode(VerificationProfile.self, from: data)
        } catch {
            throw VerificationError.invalidProfile("Invalid .tilde/verify.json: \(error.localizedDescription)")
        }
        try validate(profile)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let normalized = try encoder.encode(profile)
        return LoadedVerificationProfile(
            profile: profile,
            profileHash: VerificationHash.sha256(normalized),
            filePath: fileURL.path
        )
    }

    private func validate(_ profile: VerificationProfile) throws {
        guard profile.version == 1 else {
            throw VerificationError.invalidProfile("Unsupported verification profile version \(profile.version)")
        }
        guard !profile.checks.isEmpty else {
            throw VerificationError.invalidProfile("Verification profile must define at least one check")
        }
        guard profile.checks.contains(where: \.required) else {
            throw VerificationError.invalidProfile("Verification profile must define at least one required check")
        }

        var identifiers = Set<String>()
        let allowedIDCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        for check in profile.checks {
            guard !check.id.isEmpty,
                  check.id.unicodeScalars.allSatisfy(allowedIDCharacters.contains) else {
                throw VerificationError.invalidProfile(
                    "Check IDs may contain only letters, numbers, period, underscore, and hyphen"
                )
            }
            guard identifiers.insert(check.id).inserted else {
                throw VerificationError.invalidProfile("Duplicate verification check ID: \(check.id)")
            }
            guard !check.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VerificationError.invalidProfile("Verification check \(check.id) needs a display name")
            }
            guard !check.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VerificationError.invalidProfile("Verification check \(check.id) has an empty command")
            }
            guard (1...3_600).contains(check.timeoutSeconds) else {
                throw VerificationError.invalidProfile(
                    "Verification check \(check.id) timeout must be between 1 and 3600 seconds"
                )
            }
        }
    }
}
