import Foundation

public actor VerificationReceiptStore {
    private let fileURL: URL
    private var records: [String: VerificationRecord]?

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL(filename: "verification-receipts.json")
    }

    public func record(for worktreeID: String) -> VerificationRecord? {
        loadIfNeeded()
        return records?[worktreeID]
    }

    public func save(_ record: VerificationRecord) throws {
        loadIfNeeded()
        records?[record.worktreeID] = record
        try persist()
    }

    public func clear(worktreeID: String) throws {
        loadIfNeeded()
        records?.removeValue(forKey: worktreeID)
        try persist()
    }

    private func loadIfNeeded() {
        guard records == nil else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? Self.decoder.decode([String: VerificationRecord].self, from: data) else {
            records = [:]
            return
        }
        records = decoded
    }

    private func persist() throws {
        guard let records else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try Self.encoder.encode(records)
        try data.write(to: fileURL, options: .atomic)
    }

    fileprivate static func defaultURL(filename: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Tilde", isDirectory: true).appendingPathComponent(filename)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public actor VerificationProfileTrustStore {
    private let fileURL: URL
    private var trustedTokens: Set<String>?

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? VerificationReceiptStore.defaultURL(filename: "verification-trust.json")
    }

    public func isTrusted(repositoryID: String, profileHash: String) -> Bool {
        loadIfNeeded()
        return trustedTokens?.contains(Self.token(repositoryID: repositoryID, profileHash: profileHash)) == true
    }

    public func trust(repositoryID: String, profileHash: String) throws {
        loadIfNeeded()
        trustedTokens?.insert(Self.token(repositoryID: repositoryID, profileHash: profileHash))
        try persist()
    }

    private func loadIfNeeded() {
        guard trustedTokens == nil else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            trustedTokens = []
            return
        }
        trustedTokens = Set(decoded)
    }

    private func persist() throws {
        guard let trustedTokens else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(trustedTokens.sorted())
        try data.write(to: fileURL, options: .atomic)
    }

    private static func token(repositoryID: String, profileHash: String) -> String {
        VerificationHash.sha256("\(repositoryID):\(profileHash)")
    }
}
