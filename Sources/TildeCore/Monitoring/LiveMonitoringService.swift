import Foundation

public protocol LiveDiagnosticCoordinating: Sendable {
    func sampleSystem(previous: SystemSnapshot?, metrics: Set<LiveMetric>) async -> SystemSnapshot
    func runCodexDiagnostics() async -> Availability<CodexDiagnosticSnapshot>
    func runCursorDiagnostics() async -> Availability<CursorUsageSnapshot>
    func runClaudeDiagnostics() async -> Availability<ClaudeUsageSnapshot>
}

extension MonitoringCoordinator: LiveDiagnosticCoordinating {}

public actor LiveMonitoringService {
    private let coordinator: any LiveDiagnosticCoordinating
    private let policy: AdaptiveSamplingPolicy
    private var continuations: [UUID: AsyncStream<DiagnosticReport>.Continuation] = [:]
    private var activePresentations = Set<UUID>()
    private var loopTask: Task<Void, Never>?
    private var latestReport: DiagnosticReport?
    private var lastSampled: [LiveMetric: Date] = [:]
    private var isRefreshing = false
    private var pendingForcedRefresh = false

    public init(
        coordinator: any LiveDiagnosticCoordinating = MonitoringCoordinator(),
        policy: AdaptiveSamplingPolicy = .standard
    ) {
        self.coordinator = coordinator
        self.policy = policy
    }

    public func reports() -> AsyncStream<DiagnosticReport> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<DiagnosticReport>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[id] = continuation
        if let latestReport {
            continuation.yield(latestReport)
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        startLoopIfNeeded()
        return stream
    }

    public func setPresentation(_ id: UUID, isActive: Bool) {
        if isActive {
            activePresentations.insert(id)
        } else {
            activePresentations.remove(id)
        }
    }

    public func refreshNow() async {
        await refresh(forceAll: true)
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
        activePresentations.removeAll()
    }

    private var isForeground: Bool {
        !activePresentations.isEmpty
    }

    private func startLoopIfNeeded() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func removeSubscriber(_ id: UUID) {
        continuations.removeValue(forKey: id)
        guard continuations.isEmpty else { return }
        loopTask?.cancel()
        loopTask = nil
    }

    private func runLoop() async {
        while !Task.isCancelled {
            await refresh(forceAll: false)
            let interval = policy.schedulerTick(isForeground: isForeground)
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                break
            }
        }
    }

    private func refresh(forceAll: Bool) async {
        if isRefreshing {
            pendingForcedRefresh = pendingForcedRefresh || forceAll
            return
        }

        isRefreshing = true
        var shouldForce = forceAll
        repeat {
            pendingForcedRefresh = false
            await performRefresh(forceAll: shouldForce)
            shouldForce = pendingForcedRefresh
        } while shouldForce && !Task.isCancelled
        isRefreshing = false
    }

    private func performRefresh(forceAll: Bool) async {
        let now = Date()
        let due = forceAll
            ? Set(LiveMetric.allCases)
            : policy.dueMetrics(lastSampled: lastSampled, now: now, isForeground: isForeground)
        let systemMetrics = due.subtracting([.codex, .cursor, .claude])
        let previousSystem = latestReport?.system
        let needsCodex = due.contains(.codex)
        let needsCursor = due.contains(.cursor)
        let needsClaude = due.contains(.claude)

        let system = await coordinator.sampleSystem(previous: previousSystem, metrics: systemMetrics)

        let codex: Availability<CodexDiagnosticSnapshot>
        if needsCodex {
            codex = await coordinator.runCodexDiagnostics()
        } else {
            codex = latestReport?.codex ?? .unavailable(reason: "Waiting for first Codex sample")
        }

        let cursor: Availability<CursorUsageSnapshot>
        if needsCursor {
            cursor = await coordinator.runCursorDiagnostics()
        } else {
            cursor = latestReport?.cursor ?? .unavailable(reason: "Waiting for first Cursor sample")
        }

        let claude: Availability<ClaudeUsageSnapshot>
        if needsClaude {
            claude = await coordinator.runClaudeDiagnostics()
        } else {
            claude = latestReport?.claude ?? .unavailable(reason: "Waiting for first Claude sample")
        }

        let report = DiagnosticReport(system: system, codex: codex, cursor: cursor, claude: claude)

        for metric in due {
            lastSampled[metric] = now
        }
        latestReport = report
        for continuation in continuations.values {
            continuation.yield(report)
        }
    }
}
