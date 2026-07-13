import Foundation

public actor VerificationService {
    private let profileLoader: VerificationProfileLoader
    private let fingerprintProvider: ChangeFingerprintProvider
    private let receiptStore: VerificationReceiptStore
    private let trustStore: VerificationProfileTrustStore
    private let dismissalStore: VerificationDismissalStore
    private let runner: VerificationCommandRunner
    private var runningWorktreeID: String?
    private var activeCheckName: String?

    public init(
        profileLoader: VerificationProfileLoader = VerificationProfileLoader(),
        fingerprintProvider: ChangeFingerprintProvider = ChangeFingerprintProvider(),
        receiptStore: VerificationReceiptStore = VerificationReceiptStore(),
        trustStore: VerificationProfileTrustStore = VerificationProfileTrustStore(),
        dismissalStore: VerificationDismissalStore = VerificationDismissalStore(),
        runner: VerificationCommandRunner = VerificationCommandRunner()
    ) {
        self.profileLoader = profileLoader
        self.fingerprintProvider = fingerprintProvider
        self.receiptStore = receiptStore
        self.trustStore = trustStore
        self.dismissalStore = dismissalStore
        self.runner = runner
    }

    public func snapshot(rootPath: String?) async -> VerificationSnapshot {
        guard let rootPath else { return .unavailable }
        do {
            guard let loadedProfile = try profileLoader.load(from: rootPath) else {
                return VerificationSnapshot(
                    state: .unconfigured,
                    projectRoot: rootPath
                )
            }
            let changeSet = try fingerprintProvider.snapshot(
                rootPath: rootPath,
                profileHash: loadedProfile.profileHash,
                configuredBase: loadedProfile.profile.base
            )
            if runningWorktreeID == changeSet.worktreeID {
                return VerificationSnapshot(
                    state: .running,
                    projectRoot: rootPath,
                    changeSet: changeSet,
                    loadedProfile: loadedProfile,
                    activeCheckName: activeCheckName
                )
            }
            let trusted = await trustStore.isTrusted(
                repositoryID: changeSet.repositoryID,
                profileHash: loadedProfile.profileHash
            )
            let record = await receiptStore.record(for: changeSet.worktreeID)
            let dismissed = await dismissalStore.isDismissed(
                worktreeID: changeSet.worktreeID,
                fingerprint: changeSet.fingerprint
            )
            return snapshot(
                rootPath: rootPath,
                changeSet: changeSet,
                loadedProfile: loadedProfile,
                record: record,
                trusted: trusted,
                dismissed: dismissed
            )
        } catch {
            return VerificationSnapshot(
                state: .unavailable,
                projectRoot: rootPath,
                message: error.localizedDescription
            )
        }
    }

    public func run(
        rootPath: String,
        trustingProfile: Bool = false,
        expectedProfileHash: String
    ) async throws -> VerificationSnapshot {
        guard let loadedProfile = try profileLoader.load(from: rootPath) else {
            return VerificationSnapshot(state: .unconfigured, projectRoot: rootPath)
        }
        guard loadedProfile.profileHash == expectedProfileHash else {
            throw VerificationError.profileChanged
        }
        let changeSet = try fingerprintProvider.snapshot(
            rootPath: rootPath,
            profileHash: loadedProfile.profileHash,
            configuredBase: loadedProfile.profile.base
        )
        guard runningWorktreeID == nil else { throw VerificationError.runInProgress }

        if trustingProfile {
            try await trustStore.trust(
                repositoryID: changeSet.repositoryID,
                profileHash: loadedProfile.profileHash
            )
        } else {
            let trusted = await trustStore.isTrusted(
                repositoryID: changeSet.repositoryID,
                profileHash: loadedProfile.profileHash
            )
            guard trusted else { throw VerificationError.profileNotTrusted }
        }

        runningWorktreeID = changeSet.worktreeID
        activeCheckName = nil
        defer {
            runningWorktreeID = nil
            activeCheckName = nil
        }

        let result = try await runner.run(
            checks: loadedProfile.profile.checks,
            in: changeSet.worktreePath
        ) { [weak self] checkName in
            await self?.setActiveCheckName(checkName)
        }
        let record = VerificationRecord(
            repositoryID: changeSet.repositoryID,
            worktreeID: changeSet.worktreeID,
            baseOID: changeSet.baseOID,
            mergeBaseOID: changeSet.mergeBaseOID,
            headOID: changeSet.headOID,
            fingerprint: changeSet.fingerprint,
            profileHash: loadedProfile.profileHash,
            receipts: result.receipts
        )
        try await dismissalStore.clear(worktreeID: changeSet.worktreeID)
        try await receiptStore.save(record)

        guard let currentProfile = try profileLoader.load(from: rootPath) else {
            return VerificationSnapshot(state: .unconfigured, projectRoot: rootPath)
        }
        let currentChangeSet = try fingerprintProvider.snapshot(
            rootPath: rootPath,
            profileHash: currentProfile.profileHash,
            configuredBase: currentProfile.profile.base
        )
        let trusted = await trustStore.isTrusted(
            repositoryID: currentChangeSet.repositoryID,
            profileHash: currentProfile.profileHash
        )
        var final = snapshot(
            rootPath: rootPath,
            changeSet: currentChangeSet,
            loadedProfile: currentProfile,
            record: record,
            trusted: trusted
        )
        final.outputExcerpt = result.outputExcerpt
        return final
    }

    public func cancel() async {
        await runner.cancel()
    }

    public func clearReceipt(rootPath: String) async throws -> VerificationSnapshot {
        guard let loadedProfile = try profileLoader.load(from: rootPath) else {
            return VerificationSnapshot(state: .unconfigured, projectRoot: rootPath)
        }
        let changeSet = try fingerprintProvider.snapshot(
            rootPath: rootPath,
            profileHash: loadedProfile.profileHash,
            configuredBase: loadedProfile.profile.base
        )
        guard runningWorktreeID != changeSet.worktreeID else {
            throw VerificationError.runInProgress
        }
        try await receiptStore.clear(worktreeID: changeSet.worktreeID)
        try await dismissalStore.dismiss(
            worktreeID: changeSet.worktreeID,
            fingerprint: changeSet.fingerprint
        )
        let trusted = await trustStore.isTrusted(
            repositoryID: changeSet.repositoryID,
            profileHash: loadedProfile.profileHash
        )
        return snapshot(
            rootPath: rootPath,
            changeSet: changeSet,
            loadedProfile: loadedProfile,
            record: nil,
            trusted: trusted,
            dismissed: true
        )
    }

    private func setActiveCheckName(_ name: String) {
        activeCheckName = name
    }

    private func snapshot(
        rootPath: String,
        changeSet: ChangeSet,
        loadedProfile: LoadedVerificationProfile,
        record: VerificationRecord?,
        trusted: Bool,
        dismissed: Bool = false
    ) -> VerificationSnapshot {
        guard trusted else {
            return VerificationSnapshot(
                state: .untrusted,
                projectRoot: rootPath,
                changeSet: changeSet,
                loadedProfile: loadedProfile
            )
        }
        guard let record else {
            return VerificationSnapshot(
                state: dismissed ? .dismissed : .missing,
                projectRoot: rootPath,
                changeSet: changeSet,
                loadedProfile: loadedProfile
            )
        }
        guard record.repositoryID == changeSet.repositoryID,
              record.worktreeID == changeSet.worktreeID,
              record.profileHash == loadedProfile.profileHash,
              record.fingerprint == changeSet.fingerprint else {
            return VerificationSnapshot(
                state: .stale,
                projectRoot: rootPath,
                changeSet: changeSet,
                loadedProfile: loadedProfile,
                record: record,
                receipts: record.receipts
            )
        }

        let receiptsByID = Dictionary(uniqueKeysWithValues: record.receipts.map { ($0.checkID, $0) })
        let requiredChecks = loadedProfile.profile.checks.filter(\.required)
        let requiredReceipts = requiredChecks.compactMap { check -> CheckReceipt? in
            guard let receipt = receiptsByID[check.id],
                  receipt.commandHash == VerificationHash.sha256(check.command) else { return nil }
            return receipt
        }
        let state: VerificationState
        if requiredReceipts.contains(where: { $0.outcome == .failed || $0.outcome == .timedOut }) {
            state = .failed
        } else if requiredReceipts.count < requiredChecks.count
                    || requiredReceipts.contains(where: { $0.outcome == .cancelled }) {
            state = requiredReceipts.isEmpty ? .missing : .partial
        } else if requiredReceipts.allSatisfy({ $0.outcome == .passed }) {
            state = .verified
        } else {
            state = .partial
        }
        return VerificationSnapshot(
            state: state,
            projectRoot: rootPath,
            changeSet: changeSet,
            loadedProfile: loadedProfile,
            record: record,
            receipts: record.receipts
        )
    }
}
