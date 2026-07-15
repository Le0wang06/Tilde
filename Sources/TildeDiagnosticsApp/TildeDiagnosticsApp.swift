import AppKit
import SwiftUI
import TildeCore

@main
struct TildeDiagnosticsApp: App {
    @NSApplicationDelegateAdaptor(TildeAppDelegate.self) private var appDelegate
    @StateObject private var model: DiagnosticViewModel

    init() {
        let model = DiagnosticViewModel()
        _model = StateObject(wrappedValue: model)
        Task { @MainActor in
            model.startIfNeeded()
            TildeAppDelegate.shared?.model = model
            AttentionBannerCenter.shared.install(model: model)
            MenuBarStatusItemController.shared.install(model: model)
            AttentionBannerSmokeTest.runIfRequested(model: model)
            ReadmeAssetCapture.runIfRequested(model: model)
        }
    }

    var body: some Scene {
        WindowGroup("Tilde", id: "diagnostics") {
            DiagnosticContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 560)
        }
        .defaultSize(width: 920, height: 780)
        // Menu bar item is an AppKit NSStatusItem so today's AI spend is always visible.
        // Main window stays closed until Open is pressed in the status-item panel.
    }
}

@MainActor
final class TildeAppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: TildeAppDelegate?

    var model: DiagnosticViewModel?
    private var hostedMainWindow: NSWindow?
    private var openMainWindowObserver: NSObjectProtocol?
    private var deepLinkObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        // Stay in the menu bar only — don't steal focus or pop the main window.
        NSApp.setActivationPolicy(.accessory)
        AppIconSupport.applyApplicationIcon()
        DispatchQueue.main.async {
            for window in NSApp.windows where window.isVisible {
                window.orderOut(nil)
            }
        }

        openMainWindowObserver = NotificationCenter.default.addObserver(
            forName: .tildeOpenMainWindow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.presentMainWindow()
            }
        }

        deepLinkObserver = NotificationCenter.default.addObserver(
            forName: .tildeHandleDeepLink,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let url = note.object as? URL
            Task { @MainActor in
                if let url {
                    self?.handleDeepLink(url)
                }
            }
        }

        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(0x4755524C), // 'GURL'
            andEventID: AEEventID(0x4755524C) // 'GURL'
        )
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(0x2D2D2D2D))?.stringValue, // keyDirectObject '----'
              let url = URL(string: string) else { return }
        handleDeepLink(url)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleDeepLink(url)
        }
    }

    func handleDeepLink(_ url: URL) {
        guard let action = DeepLinkAction.parse(url: url) else { return }
        model?.startIfNeeded()
        switch action {
        case .openWindow:
            presentMainWindow()
        case .refresh:
            model?.refresh()
        case .copyStatus:
            model?.copyStatusToPasteboard()
        case .openCursor:
            model?.openCursor()
        case .focus(let mode):
            model?.applyFocusMode(mode)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock isn't shown in accessory mode; ignore reopen.
        false
    }

    /// Show the full diagnostics window; switches to regular activation so it can come forward.
    func presentMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let hostedMainWindow, hostedMainWindow.isVisible {
            hostedMainWindow.makeKeyAndOrderFront(nil)
            return
        }

        let existing = NSApp.windows.filter {
            $0.canBecomeMain && !($0.className.contains("NSStatusBar"))
        }
        if let window = existing.first {
            window.makeKeyAndOrderFront(nil)
            return
        }

        guard let model else { return }
        let host = NSHostingController(
            rootView: DiagnosticContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 560)
        )
        let window = NSWindow(contentViewController: host)
        window.title = "Tilde"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 920, height: 780))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        hostedMainWindow = window
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // If the user closed every window, return to menu-bar-only mode.
        let hasMain = NSApp.windows.contains {
            $0.isVisible && $0.canBecomeMain && !($0.className.contains("NSStatusBar"))
        }
        if !hasMain, NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

extension TildeAppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === hostedMainWindow {
            hostedMainWindow = nil
        }
        DispatchQueue.main.async {
            let hasMain = NSApp.windows.contains {
                $0.isVisible && $0.canBecomeMain && !($0.className.contains("NSStatusBar"))
            }
            if !hasMain {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

@MainActor
final class DiagnosticViewModel: ObservableObject {
    @Published var report: DiagnosticReport?
    @Published var runState = DiagnosticRunState.idle
    @Published private(set) var history: [LiveMetricSample] = []
    /// Compact daily AI spend shown in the macOS menu bar title.
    @Published private(set) var menuBarTitle: String = "$—"
    @Published private(set) var fanBoost: FanBoostController.Snapshot = .idle
    @Published private(set) var buildPulse = BuildPulseSnapshot()
    @Published private(set) var slowdown = SlowdownAdvice.none
    @Published private(set) var projectContext = ProjectContextSnapshot.empty
    @Published private(set) var focusMode: FocusMode = .off
    @Published private(set) var todaySummary = SessionDiaryTodaySummary.empty
    @Published private(set) var agentAttention = AgentAttentionSnapshot.unavailable
    @Published private(set) var trustPacket = TrustPacketSnapshot.unavailable
    @Published private(set) var verification = VerificationSnapshot.unavailable
    @Published private(set) var recoveryCapsule: RecoveryCapsule?
    @Published private(set) var decisionQueue = DecisionQueueSnapshot.empty
    private let liveMonitoring = LiveMonitoringService()
    private let fanBoostController = FanBoostController()
    private let buildPulseMonitor = BuildPulseMonitor()
    private let projectContextMonitor = ProjectContextMonitor()
    private let gitWorktreeDiscovery = GitWorktreeDiscovery()
    private let slowdownNotifier = SlowdownNotifier()
    private let sessionDiary = SessionDiaryStore()
    private let herdrAgentProvider: HerdrAgentProvider
    private let agentAttentionMonitor: AgentAttentionMonitor
    private let agentAttentionNotifier = AgentAttentionNotifier()
    private let trustPacketProvider = TrustPacketProvider()
    private let verificationService = VerificationService()
    private let recoveryCapsuleStore = RecoveryCapsuleStore()
    private var historyBuffer = LiveMetricHistory()
    private var subscriptionTask: Task<Void, Never>?
    private var buildPulseTask: Task<Void, Never>?
    private var projectContextTask: Task<Void, Never>?
    private var speedWriteTask: Task<Void, Never>?
    private var agentAttentionTask: Task<Void, Never>?
    private var verificationRunTask: Task<Void, Never>?
    private var decisionEvidence: [DecisionQueueEvidence] = []
    private var decisionDiscoveryNotes: [String] = []
    private var lastFullDecisionRefreshAt: Date?
    private var didAskNotificationAuth = false
    private var didRecordAppStart = false
    private var lastLoggedBuildPhase: BuildPulsePhase = .idle
    private var lastLoggedSlowdown: SlowdownSeverity = .none
    private var freezeIdentityForReadmeCapture = false
    private let menuBarPresentationID = UUID()

    init() {
        let provider = HerdrAgentProvider()
        herdrAgentProvider = provider
        agentAttentionMonitor = AgentAttentionMonitor {
            await provider.snapshot()
        }
    }

    var menuBarSymbol: String {
        if runState == .running { return "ellipsis.circle" }
        guard let report else { return "waveform.path.ecg" }
        if report.system.thermalState == .critical { return "exclamationmark.triangle.fill" }
        if case .available(let memory) = report.system.memory, memory.pressure == .critical {
            return "exclamationmark.triangle.fill"
        }
        return "waveform.path.ecg"
    }

    var isFanBoostEnabled: Bool { fanBoost.isEnabled }

    func startIfNeeded() {
        guard subscriptionTask == nil else { return }
        runState.apply(.start)
        // Keep background sampling active for the menu-bar title even when
        // the panel / window are closed.
        Task {
            await liveMonitoring.setPresentation(menuBarPresentationID, isActive: true)
            // If a previous session left fans forced on, release them.
            if !fanBoost.isEnabled {
                await fanBoostController.forceReleaseFans()
                await MainActor.run { self.fanBoost = .idle }
            }
        }
        if !didRecordAppStart {
            didRecordAppStart = true
            recordDiary(.init(kind: .appStarted, summary: "Tilde started"))
        } else {
            Task {
                let summary = await sessionDiary.todaySummary()
                await MainActor.run { self.todaySummary = summary }
            }
        }
        subscriptionTask = Task { [weak self] in
            guard let self else { return }
            let reports = await liveMonitoring.reports()
            for await report in reports {
                guard !Task.isCancelled else { break }
                self.apply(report: report)
            }
        }
        buildPulseTask?.cancel()
        buildPulseTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let snapshot = await self.buildPulseMonitor.snapshot()
                self.noteBuildPulseTransition(snapshot)
                self.buildPulse = snapshot
                if let report = self.report {
                    self.publishMenuBarTitle(
                        codex: report.codex,
                        cursor: report.cursor,
                        build: snapshot,
                        slowdown: self.slowdown,
                        project: self.projectContext,
                        focus: self.focusMode
                    )
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        projectContextTask?.cancel()
        projectContextTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let preferredRoot = self.agentAttention.agents.first(where: { $0.focused })?.projectRoot
                    ?? self.agentAttention.agents.first(where: { $0.state == .working })?.projectRoot
                if !self.freezeIdentityForReadmeCapture {
                    await self.refreshProjectAndDecisionEvidence(preferredRoot: preferredRoot)
                }
                if let report = self.report {
                    self.publishMenuBarTitle(
                        codex: report.codex,
                        cursor: report.cursor,
                        build: self.buildPulse,
                        slowdown: self.slowdown,
                        project: self.projectContext,
                        focus: self.focusMode
                    )
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        agentAttentionTask?.cancel()
        agentAttentionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let refresh = await self.agentAttentionMonitor.refresh()
                if !self.freezeIdentityForReadmeCapture {
                    self.agentAttention = refresh.snapshot
                    self.agentAttentionNotifier.post(
                        refresh.events,
                        logoAttachment: AppIconSupport.makeLogoAttachment()
                    )
                    AttentionSoundPlayer.play(for: refresh.events)
                    for event in refresh.events {
                        self.recordDiary(.init(
                            kind: event.kind == .needsInput ? .agentNeedsInput : .agentCompleted,
                            summary: "\(event.agent.projectName) · \(event.agent.state.label)",
                            detail: "\(event.agent.agent) in \(event.agent.cwd)"
                        ))
                    }
                    self.refreshDecisionQueue()
                }
                if let report = self.report {
                    self.publishMenuBarTitle(
                        codex: report.codex,
                        cursor: report.cursor,
                        build: self.buildPulse,
                        slowdown: self.slowdown,
                        project: self.projectContext,
                        focus: self.focusMode
                    )
                }
                // Poll faster while an agent is working so short Q&A turns
                // aren't missed between samples (Herdr flips working→idle quickly).
                try? await Task.sleep(
                    for: .milliseconds(refresh.snapshot.workingCount > 0 ? 500 : 2000)
                )
            }
        }
    }

    private func refreshDecisionQueue() {
        if decisionEvidence.isEmpty {
            decisionQueue = DecisionQueueComposer.compose(
                project: projectContext,
                trust: trustPacket,
                verification: verification,
                agents: agentAttention,
                build: buildPulse
            )
        } else {
            decisionQueue = DecisionQueueComposer.compose(
                changes: decisionEvidence,
                agents: agentAttention,
                discoveryNotes: decisionDiscoveryNotes
            )
        }
    }

    private func refreshProjectAndDecisionEvidence(preferredRoot: String?) async {
        let activeProject = await projectContextMonitor.snapshot(preferredRoot: preferredRoot)
        let activeVerification = await verificationService.snapshot(rootPath: activeProject.rootPath)
        let activeTrust = await trustPacketProvider.snapshot(
            rootPath: activeProject.rootPath,
            build: buildPulse,
            ciStatus: activeProject.ciStatus,
            behind: activeProject.behind,
            verification: activeVerification
        )
        projectContext = activeProject
        verification = activeVerification
        trustPacket = activeTrust
        recoveryCapsule = await recoveryCapsuleStore.update(
            project: activeProject,
            attention: agentAttention,
            trust: activeTrust,
            build: buildPulse
        )

        let now = Date()
        let needsFullRefresh = decisionEvidence.isEmpty
            || lastFullDecisionRefreshAt.map { now.timeIntervalSince($0) >= 30 } != false
        guard needsFullRefresh else {
            upsertDecisionEvidence(.init(
                project: activeProject,
                trust: activeTrust,
                verification: activeVerification
            ))
            refreshDecisionQueue()
            return
        }

        let seedPaths = ([activeProject.rootPath].compactMap { $0 }
            + agentAttention.agents.map { $0.projectRoot ?? $0.cwd })
        let discovery = await gitWorktreeDiscovery.snapshot(seedPaths: seedPaths)
        var refreshed: [DecisionQueueEvidence] = []
        for worktree in discovery.worktrees where !worktree.isPrunable {
            let context = await projectContextMonitor.snapshot(rootPath: worktree.path)
            guard context.rootPath != nil else { continue }
            let exactVerification = await verificationService.snapshot(rootPath: worktree.path)
            let exactTrust = await trustPacketProvider.snapshot(
                rootPath: worktree.path,
                build: BuildPulseSnapshot(),
                ciStatus: context.ciStatus,
                behind: context.behind,
                verification: exactVerification
            )
            refreshed.append(.init(
                project: context,
                trust: exactTrust,
                verification: exactVerification
            ))
        }
        if refreshed.isEmpty, activeProject.rootPath != nil {
            refreshed = [.init(
                project: activeProject,
                trust: activeTrust,
                verification: activeVerification
            )]
        }
        decisionEvidence = refreshed
        decisionDiscoveryNotes = discovery.notes
        lastFullDecisionRefreshAt = now
        refreshDecisionQueue()
    }

    private func upsertDecisionEvidence(_ evidence: DecisionQueueEvidence) {
        guard let root = evidence.project.rootPath else { return }
        let key = canonicalizePath(root)
        if let index = decisionEvidence.firstIndex(where: {
            $0.project.rootPath.map(canonicalizePath) == key
        }) {
            decisionEvidence[index] = evidence
        } else {
            decisionEvidence.append(evidence)
        }
    }

    /// Replace personal project/agent paths with anonymous demo labels for README captures.
    func applyReadmeDemoStubs() {
        freezeIdentityForReadmeCapture = true

        if let report {
            let demoCodex = CodexDiagnosticSnapshot(
                executablePath: "/usr/local/bin/codex",
                version: "demo",
                isAuthenticated: true,
                accountType: "chatgpt",
                planType: "demo",
                primaryLimit: CodexRateLimitWindow(
                    usedPercent: 33,
                    resetsAt: Date().addingTimeInterval(2 * 60 * 60),
                    durationMinutes: 300
                ),
                secondaryLimit: CodexRateLimitWindow(
                    usedPercent: 18,
                    resetsAt: Date().addingTimeInterval(4 * 24 * 60 * 60),
                    durationMinutes: 10_080
                ),
                tokensToday: 128_000,
                dailySpend: DailySpendReading(
                    provider: .codex,
                    cents: 126,
                    basis: .estimatedFromTokenBreakdown,
                    observedFrom: Calendar.current.startOfDay(for: Date())
                ),
                estimatedCreditsToday: 31.5,
                lifetimeTokens: nil,
                threadCount: 3,
                notes: []
            )
            let demoCursor = CursorUsageSnapshot(
                remainingPercent: 45,
                usedPercent: 55,
                planName: "pro",
                billingCycleEnd: Date().addingTimeInterval(12 * 24 * 60 * 60),
                displayMessage: "55% of included usage used",
                dailySpend: DailySpendReading(
                    provider: .cursor,
                    cents: 312,
                    basis: .providerReported,
                    observedFrom: Calendar.current.startOfDay(for: Date())
                )
            )
            self.report = DiagnosticReport(
                system: report.system,
                codex: .available(demoCodex),
                cursor: .available(demoCursor)
            )
        }

        projectContext = ProjectContextSnapshot(
            projectName: "checkout-api",
            rootPath: "/Users/you/Projects/checkout-api",
            branch: "feature/payments",
            isDirty: true,
            ahead: 2,
            behind: 0,
            ciStatus: .success,
            ciSummary: "CI · pass"
        )

        agentAttention = AgentAttentionSnapshot(
            agents: [
                AgentAttentionItem(
                    id: "demo-1",
                    terminalID: "term-1",
                    paneID: nil,
                    workspaceID: nil,
                    agent: "codex",
                    state: .done,
                    cwd: "/Users/you/Projects/checkout-api",
                    projectRoot: "/Users/you/Projects/checkout-api",
                    projectName: "checkout-api",
                    branch: "feature/payments",
                    focused: true
                ),
                AgentAttentionItem(
                    id: "demo-2",
                    terminalID: "term-2",
                    paneID: nil,
                    workspaceID: nil,
                    agent: "cursor",
                    state: .working,
                    cwd: "/Users/you/Projects/storefront",
                    projectRoot: "/Users/you/Projects/storefront",
                    projectName: "storefront",
                    branch: "feature/hud",
                    focused: false
                ),
                AgentAttentionItem(
                    id: "demo-3",
                    terminalID: "term-3",
                    paneID: nil,
                    workspaceID: nil,
                    agent: "codex",
                    state: .idle,
                    cwd: "/Users/you/Projects/billing-worker",
                    projectRoot: "/Users/you/Projects/billing-worker",
                    projectName: "billing-worker",
                    branch: "main",
                    focused: false
                ),
            ],
            sampledAt: Date(),
            providerAvailable: true
        )

        trustPacket = TrustPacketSnapshot(
            state: .ready,
            projectRoot: "/Users/you/Projects/checkout-api",
            changedFiles: 4,
            additions: 128,
            deletions: 19,
            comparisonBase: "main"
        )
        let demoProfile = VerificationProfile(
            base: "origin/main",
            checks: [
                VerificationCheck(id: "tests", name: "Tests", command: "./Scripts/test.sh"),
                VerificationCheck(id: "build", name: "Build", command: "swift build"),
            ]
        )
        let demoReceipts = demoProfile.checks.map { check in
            CheckReceipt(
                checkID: check.id,
                checkName: check.name,
                commandHash: "demo",
                required: true,
                startedAt: Date().addingTimeInterval(-20),
                finishedAt: Date(),
                duration: check.id == "tests" ? 12.4 : 4.8,
                exitStatus: 0,
                outcome: .passed
            )
        }
        verification = VerificationSnapshot(
            state: .verified,
            projectRoot: "/Users/you/Projects/checkout-api",
            changeSet: ChangeSet(
                repositoryID: "demo",
                worktreeID: "demo-worktree",
                worktreePath: "/Users/you/Projects/checkout-api",
                baseRef: "origin/main",
                baseOID: "base",
                mergeBaseOID: "merge-base",
                headOID: "head",
                changedFiles: 4,
                fingerprint: ChangeFingerprint(value: "a1b2c3d4demo")
            ),
            loadedProfile: LoadedVerificationProfile(
                profile: demoProfile,
                profileHash: "demo-profile",
                filePath: "/Users/you/Projects/checkout-api/.tilde/verify.json"
            ),
            receipts: demoReceipts
        )
        decisionEvidence = [
            DecisionQueueEvidence(
                project: projectContext,
                trust: trustPacket,
                verification: verification
            ),
            DecisionQueueEvidence(
                project: ProjectContextSnapshot(
                    projectName: "storefront",
                    rootPath: "/Users/you/Projects/storefront",
                    branch: "feature/hud",
                    ciStatus: .failure,
                    ciSummary: "CI · fail",
                    pullRequestURL: "https://example.test/storefront/pull/42"
                ),
                trust: TrustPacketSnapshot(
                    state: .needsVerification,
                    projectRoot: "/Users/you/Projects/storefront",
                    changedFiles: 3,
                    additions: 61,
                    deletions: 8,
                    comparisonBase: "main",
                    risks: [TrustRisk(kind: .ciFailed, message: "CI failed for this commit")]
                ),
                verification: VerificationSnapshot(
                    state: .failed,
                    projectRoot: "/Users/you/Projects/storefront"
                )
            ),
        ]
        decisionDiscoveryNotes = []

        recoveryCapsule = RecoveryCapsule(
            projectRoot: "/Users/you/Projects/checkout-api",
            projectName: "checkout-api",
            branch: "feature/payments",
            headline: "2 checks passed · exact change",
            nextAction: "Review the exact verified change",
            attentionCount: 1,
            verificationState: TrustPacketState.ready.rawValue,
            changedFiles: 4
        )

        todaySummary = SessionDiaryTodaySummary(
            eventCount: 11,
            builds: 3,
            slowdowns: 0,
            focusChanges: 2,
            lastEventSummary: "Agent finished · checkout-api"
        )

        buildPulse = BuildPulseSnapshot(
            phase: .finished,
            kind: .other,
            commandSummary: "Tests",
            finishedAt: Date().addingTimeInterval(-90),
            lastDuration: 12.4,
            lastSucceeded: true
        )

        menuBarTitle = "! ≈$4.38"
        MenuBarStatusItemController.shared.updateTitle(menuBarTitle, needsAttention: true)
        refreshDecisionQueue()
    }

    private func apply(report: DiagnosticReport) {
        guard !freezeIdentityForReadmeCapture else { return }
        self.report = report
        historyBuffer.append(LiveMetricSample(snapshot: report.system))
        history = historyBuffer.samples
        let advice = SlowdownAdvisor.advice(from: report.system)
        if advice.severity != lastLoggedSlowdown, advice.severity != .none {
            recordDiary(.init(
                kind: .slowdown,
                summary: advice.title,
                detail: advice.detail
            ))
        }
        lastLoggedSlowdown = advice.severity
        slowdown = advice
        if !didAskNotificationAuth, advice.severity != .none {
            didAskNotificationAuth = true
            slowdownNotifier.requestAuthorizationIfNeeded()
        }
        slowdownNotifier.postIfNeeded(advice)
        publishMenuBarTitle(
            codex: report.codex,
            cursor: report.cursor,
            build: buildPulse,
            slowdown: advice,
            project: projectContext,
            focus: focusMode
        )
        if fanBoost.isEnabled {
            Task {
                let snapshot = await fanBoostController.currentSnapshot(thermalState: report.system.thermalState)
                await MainActor.run { self.fanBoost = snapshot }
            }
        }
        runState.apply(.finish)
    }

    private func publishMenuBarTitle(
        codex: Availability<CodexDiagnosticSnapshot>,
        cursor: Availability<CursorUsageSnapshot>,
        build: BuildPulseSnapshot,
        slowdown: SlowdownAdvice,
        project: ProjectContextSnapshot,
        focus: FocusMode
    ) {
        let needsAttention = agentAttention.attentionCount > 0
        menuBarTitle = Self.makeMenuBarTitle(
            from: codex,
            cursor: cursor,
            needsAttention: needsAttention
        )
        MenuBarStatusItemController.shared.updateTitle(menuBarTitle, needsAttention: needsAttention)
        NotificationCenter.default.post(
            name: .tildeMenuBarTitleDidChange,
            object: nil,
            userInfo: [
                "title": menuBarTitle,
                "needsAttention": needsAttention,
            ]
        )
    }

    private static func makeMenuBarTitle(
        from codex: Availability<CodexDiagnosticSnapshot>,
        cursor: Availability<CursorUsageSnapshot>,
        needsAttention: Bool = false
    ) -> String {
        let spend = DailyAISpendSummary(
            codex: codex.availableValue?.dailySpend,
            cursor: cursor.availableValue?.dailySpend
        )
        return MenuBarAttentionTitle.compose(
            spendText: spend.menuBarText,
            needsAttention: needsAttention
        )
    }

    func applyFocusMode(_ mode: FocusMode) {
        focusMode = mode
        recordDiary(.init(
            kind: .focusChanged,
            summary: "Focus · \(mode.title)",
            detail: mode.detail
        ))
        if let report {
            publishMenuBarTitle(
                codex: report.codex,
                cursor: report.cursor,
                build: buildPulse,
                slowdown: slowdown,
                project: projectContext,
                focus: mode
            )
        }

        if let speed = mode.fanSpeed {
            setFanBoostSpeed(speed)
        }
        if let enabled = mode.fanEnabled {
            setFanBoostEnabled(enabled)
        }
        for bundleID in mode.quitBundleIDs {
            for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == bundleID {
                app.terminate()
            }
        }
    }

    func runVerification(trustingProfile: Bool = false) {
        guard let root = projectContext.rootPath else { return }
        startVerification(rootPath: root, trustingProfile: trustingProfile)
    }

    private func startVerification(rootPath: String, trustingProfile: Bool) {
        guard verificationRunTask == nil else { return }
        verificationRunTask = Task { [weak self] in
            guard let self else { return }
            var pending = await verificationService.snapshot(rootPath: rootPath)
            guard let expectedProfileHash = pending.loadedProfile?.profileHash else {
                verificationRunTask = nil
                return
            }
            pending.state = .running
            pending.activeCheckName = nil
            pending.message = nil
            await updateDecisionEvidence(rootPath: rootPath, verification: pending)
            let result: VerificationSnapshot
            do {
                result = try await verificationService.run(
                    rootPath: rootPath,
                    trustingProfile: trustingProfile,
                    expectedProfileHash: expectedProfileHash
                )
            } catch {
                var retryable = await verificationService.snapshot(rootPath: rootPath)
                retryable.message = error.localizedDescription
                result = retryable
            }
            guard !Task.isCancelled else { return }
            await updateDecisionEvidence(rootPath: rootPath, verification: result)
            verificationRunTask = nil
        }
    }

    private func updateDecisionEvidence(
        rootPath: String,
        verification exactVerification: VerificationSnapshot
    ) async {
        let context = await projectContextMonitor.snapshot(rootPath: rootPath)
        let exactTrust = await trustPacketProvider.snapshot(
            rootPath: rootPath,
            build: canonicalizePath(projectContext.rootPath ?? "") == canonicalizePath(rootPath)
                ? buildPulse : BuildPulseSnapshot(),
            ciStatus: context.ciStatus,
            behind: context.behind,
            verification: exactVerification
        )
        upsertDecisionEvidence(.init(
            project: context,
            trust: exactTrust,
            verification: exactVerification
        ))
        if canonicalizePath(projectContext.rootPath ?? "") == canonicalizePath(rootPath) {
            projectContext = context
            verification = exactVerification
            trustPacket = exactTrust
        }
        refreshDecisionQueue()
    }

    func cancelVerification() {
        Task {
            await verificationService.cancel()
        }
    }

    func clearVerificationResult() {
        guard verificationRunTask == nil,
              let root = projectContext.rootPath else { return }
        verificationRunTask = Task { [weak self] in
            guard let self else { return }
            let result: VerificationSnapshot
            do {
                result = try await verificationService.clearReceipt(rootPath: root)
            } catch {
                var retryable = await verificationService.snapshot(rootPath: root)
                retryable.message = error.localizedDescription
                result = retryable
            }
            guard !Task.isCancelled else { return }
            await updateDecisionEvidence(rootPath: root, verification: result)
            verificationRunTask = nil
        }
    }

    private func noteBuildPulseTransition(_ snapshot: BuildPulseSnapshot) {
        guard snapshot.phase != lastLoggedBuildPhase else { return }
        defer { lastLoggedBuildPhase = snapshot.phase }
        switch snapshot.phase {
        case .running:
            recordDiary(.init(
                kind: .buildStarted,
                summary: "\(snapshot.kind?.label ?? "Build") started",
                detail: snapshot.commandSummary
            ))
        case .finished:
            recordDiary(.init(
                kind: .buildFinished,
                summary: snapshot.statusText,
                detail: snapshot.commandSummary
            ))
        case .idle:
            break
        }
    }

    private func recordDiary(_ event: SessionDiaryEvent) {
        Task {
            await sessionDiary.record(event)
            let summary = await sessionDiary.todaySummary()
            await MainActor.run { self.todaySummary = summary }
        }
    }

    func setFanBoostEnabled(_ enabled: Bool) {
        let thermal = report?.system.thermalState ?? .unavailable
        let speed = fanBoost.speed
        if enabled {
            fanBoost = FanBoostController.Snapshot(
                isEnabled: true,
                mode: .starting,
                statusText: "Starting…",
                detailText: "0 RPM · spinning fans up to \(Int((speed * 100).rounded()))%",
                rpm: 0,
                speed: speed
            )
        } else {
            fanBoost = FanBoostController.Snapshot(
                isEnabled: false,
                mode: .off,
                statusText: "Off",
                detailText: "Drag the bar, then turn on",
                rpm: 0,
                speed: speed
            )
        }
        Task {
            let snapshot = await fanBoostController.setEnabled(enabled, thermalState: thermal)
            await MainActor.run { self.fanBoost = snapshot }
        }
    }

    func setFanBoostSpeed(_ speed: Double) {
        let thermal = report?.system.thermalState ?? .unavailable
        // Snappy local update while dragging.
        fanBoost = FanBoostController.Snapshot(
            isEnabled: fanBoost.isEnabled,
            mode: fanBoost.mode,
            statusText: fanBoost.statusText,
            detailText: fanBoost.detailText,
            rpm: fanBoost.rpm,
            speed: speed
        )
        speedWriteTask?.cancel()
        speedWriteTask = Task {
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            let snapshot = await fanBoostController.setSpeed(speed, thermalState: thermal)
            await MainActor.run { self.fanBoost = snapshot }
        }
    }

    func refresh() {
        startIfNeeded()
        runState.apply(.start)
        lastFullDecisionRefreshAt = nil
        Task {
            await liveMonitoring.refreshNow()
        }
    }

    func openCursor() {
        let candidates = [
            "/Applications/Cursor.app",
            "\(NSHomeDirectory())/Applications/Cursor.app",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func copyStatusToPasteboard() {
        var lines: [String] = [menuBarTitle]
        if let project = projectContext.projectName {
            lines.append("Project: \(project) · \(projectContext.chipText)")
        }
        if focusMode != .off {
            lines.append("Focus: \(focusMode.title)")
        }
        if slowdown.severity != .none {
            lines.append("\(slowdown.title): \(slowdown.detail)")
        }
        if buildPulse.phase != .idle {
            lines.append("Build: \(buildPulse.statusText)")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    func focusAgent(_ agent: AgentAttentionItem) {
        Task {
            guard await herdrAgentProvider.focusAgent(terminalID: agent.terminalID) else { return }
            await MainActor.run {
                let terminalBundleIDs = [
                    "com.mitchellh.ghostty",
                    "com.googlecode.iterm2",
                    "com.apple.Terminal",
                ]
                if let app = NSWorkspace.shared.runningApplications.first(where: {
                    guard let bundleID = $0.bundleIdentifier else { return false }
                    return terminalBundleIDs.contains(bundleID)
                }) {
                    app.activate()
                }
            }
        }
    }

    func performDecisionAction(_ action: DecisionAction, for item: DecisionQueueItem) {
        switch action.kind {
        case .reviewChange:
            reviewChange(at: item.worktreePath)
        case .runChecks:
            startVerification(rootPath: item.worktreePath, trustingProfile: false)
        case .trustProfile:
            startVerification(rootPath: item.worktreePath, trustingProfile: true)
        case .openAgent:
            if let terminalID = item.agentTerminalIDs.first,
               let agent = agentAttention.agents.first(where: { $0.terminalID == terminalID }) {
                focusAgent(agent)
            } else if let agent = agentAttention.agents.first(where: {
                canonicalizePath($0.projectRoot ?? $0.cwd) == canonicalizePath(item.worktreePath)
            }) {
                focusAgent(agent)
            }
        case .openPullRequest:
            guard let rawURL = item.pullRequestURL, let url = URL(string: rawURL) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    func reviewChange(at path: String) {
        let url = URL(fileURLWithPath: path)
        // Prefer Cursor when available; otherwise reveal in Finder.
        let cursor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92")
        if let cursor {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: cursor, configuration: config)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func canonicalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    func setPresentation(_ id: UUID, isActive: Bool) {
        startIfNeeded()
        Task {
            await liveMonitoring.setPresentation(id, isActive: isActive)
        }
    }
}

private struct DiagnosticContentView: View {
    @EnvironmentObject private var model: DiagnosticViewModel
    @State private var presentationID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 24) {
                    if let report = model.report {
                        overview(report)
                        liveActivity
                        resourceSection(report.system)
                        networkAndPowerSection(report.system)
                        codexSection(report.codex)
                        sensorSection(report.system.advancedSensors)
                    } else {
                        ContentUnavailableView(
                            "No Diagnostic Results",
                            systemImage: "stethoscope",
                            description: Text("Run diagnostics to test system providers and Codex connectivity.")
                        )
                        .frame(minHeight: 420)
                    }
                }
                .padding(24)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.setPresentation(presentationID, isActive: true) }
        .onDisappear { model.setPresentation(presentationID, isActive: false) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Overview")
                    .font(.title.weight(.semibold))
                HStack(spacing: 7) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(freshnessText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.runState == .running {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh All Metrics")
            .disabled(model.runState == .running)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: 1_028)
        .frame(maxWidth: .infinity)
    }

    private var freshnessText: String {
        guard let report = model.report else { return "Starting live monitoring" }
        return "\(statusText(report)) · Live at \(report.system.timestamp.formatted(date: .omitted, time: .standard))"
    }

    private var statusColor: Color {
        guard let report = model.report else { return .secondary }
        if report.system.thermalState == .critical { return .red }
        if case .available(let memory) = report.system.memory {
            return MetricColor.memoryPressure(memory.pressure)
        }
        return .green
    }

    private func overview(_ report: DiagnosticReport) -> some View {
        let codexWindow = codexDisplayWindow(report.codex)
        return HStack(spacing: 10) {
            SummaryMetric(
                title: "CPU",
                value: cpuPercent(report.system.cpu).map(percent) ?? "--",
                detail: "Live utilization",
                color: cpuPercent(report.system.cpu).map(MetricColor.utilization) ?? .secondary,
                fraction: cpuPercent(report.system.cpu).map { $0 / 100 }
            )
            SummaryMetric(
                title: "Memory",
                value: memoryPercent(report.system.memory).map(percent) ?? "--",
                detail: pressureValue(report.system.memory),
                color: memoryColor(report.system.memory),
                fraction: memoryPercent(report.system.memory).map { $0 / 100 }
            )
            SummaryMetric(
                title: "Storage",
                value: storagePercent(report.system.storage).map(percent) ?? "--",
                detail: storageValue(report.system.storage),
                color: storagePercent(report.system.storage).map(MetricColor.utilization) ?? .secondary,
                fraction: storagePercent(report.system.storage).map { $0 / 100 }
            )
            SummaryMetric(
                title: "Codex",
                value: codexWindow.map { "\($0.remainingPercent)%" } ?? "--",
                detail: codexWindow.map { "\($0.kind.label) remaining" } ?? "Allowance unavailable",
                color: codexWindow.map { MetricColor.remaining($0.remainingPercent) } ?? .secondary,
                fraction: codexWindow.map { Double($0.remainingPercent) / 100 }
            )
        }
    }

    private var liveActivity: some View {
        MonitorSection(title: "Live Activity", symbol: "chart.xyaxis.line") {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    LiveResourceChart(samples: model.history)
                        .frame(minWidth: 280, maxWidth: .infinity)
                    LiveNetworkChart(samples: model.history)
                        .frame(minWidth: 280, maxWidth: .infinity)
                }
                VStack(spacing: 12) {
                    LiveResourceChart(samples: model.history)
                    LiveNetworkChart(samples: model.history)
                }
            }
        }
    }

    private func resourceSection(_ snapshot: SystemSnapshot) -> some View {
        MonitorSection(title: "Resources", symbol: "gauge.with.dots.needle.50percent") {
            ModernSurface {
                VStack(alignment: .leading, spacing: 12) {
                    if let cpu = cpuPercent(snapshot.cpu) {
                        MetricBar(label: "CPU", value: percent(cpu), fraction: cpu / 100, color: MetricColor.utilization(cpu))
                    } else {
                        MetricBar(label: "CPU", value: "Unavailable", fraction: nil, color: .secondary)
                    }
                    if case .available(let memory) = snapshot.memory {
                        let usage = memory.totalBytes > 0 ? Double(memory.usedBytes) / Double(memory.totalBytes) * 100 : 0
                        MetricBar(
                            label: "Memory",
                            value: "\(bytes(memory.usedBytes)) / \(bytes(memory.totalBytes))",
                            fraction: usage / 100,
                            color: memoryBarColor(usage: usage, pressure: memory.pressure),
                            detail: memory.pressure.rawValue.capitalized
                        )
                        MetricRow(label: "Swap", value: bytes(memory.swapUsedBytes))
                    } else {
                        MetricBar(label: "Memory", value: "Unavailable", fraction: nil, color: .secondary)
                    }
                    if case .available(let storage) = snapshot.storage, storage.totalBytes > 0 {
                        let usage = Double(storage.usedBytes) / Double(storage.totalBytes) * 100
                        MetricBar(
                            label: "Storage",
                            value: "\(bytes(storage.usedBytes)) / \(bytes(storage.totalBytes))",
                            fraction: usage / 100,
                            color: MetricColor.utilization(usage)
                        )
                    } else {
                        MetricBar(label: "Storage", value: "Unavailable", fraction: nil, color: .secondary)
                    }
                }
            }
        }
    }

    private func networkAndPowerSection(_ snapshot: SystemSnapshot) -> some View {
        MonitorSection(title: "Network & Power", symbol: "network") {
            ModernSurface {
                VStack(alignment: .leading, spacing: 8) {
                    if case .available(let network) = snapshot.network {
                        MetricRow(label: "Download", value: network.downloadBytesPerSecond.map(rate) ?? "Collecting baseline")
                        MetricRow(label: "Upload", value: network.uploadBytesPerSecond.map(rate) ?? "Collecting baseline")
                        MetricRow(label: "Connection", value: network.interfaceName ?? "Unavailable")
                        MetricRow(label: "Local IP", value: network.localIPAddress ?? "Unavailable")
                    } else {
                        MetricRow(label: "Network", value: "Unavailable", isUnavailable: true)
                    }
                    if case .available(let battery) = snapshot.battery {
                        MetricBar(
                            label: "Battery",
                            value: battery.percent.map(percent) ?? "Unavailable",
                            fraction: battery.percent.map { $0 / 100 },
                            color: battery.percent.map { $0 <= 15 ? .red : ($0 <= 30 ? .orange : .green) } ?? .secondary,
                            detail: battery.isOnACPower ? "Adapter" : "Battery"
                        )
                    } else {
                        MetricRow(label: "Battery", value: "Unavailable", isUnavailable: true)
                    }
                    MetricRow(label: "Thermal State", value: snapshot.thermalState.rawValue.capitalized)
                }
            }
        }
    }

    @ViewBuilder
    private func codexSection(_ availability: Availability<CodexDiagnosticSnapshot>) -> some View {
        MonitorSection(title: "Codex", symbol: "terminal") {
            ModernSurface {
                VStack(alignment: .leading, spacing: 10) {
                    switch availability {
                    case .available(let codex):
                        let windows = codex.rateLimitWindows.sorted {
                            codexWindowOrder($0.kind) < codexWindowOrder($1.kind)
                        }
                        if windows.isEmpty {
                            MetricRow(label: "Usage windows", value: "Not reported", isUnavailable: true)
                        }
                        ForEach(windows.indices, id: \.self) { index in
                            let window = windows[index]
                            MetricBar(
                                label: codexWindowLabel(window),
                                value: "\(window.remainingPercent)% remaining",
                                fraction: Double(window.remainingPercent) / 100,
                                color: MetricColor.remaining(window.remainingPercent),
                                detail: window.resetsAt.map { "Resets \($0.formatted(date: .abbreviated, time: .shortened))" }
                            )
                        }
                        MetricRow(label: "Tokens Today", value: codex.tokensToday.map(formatCount) ?? "Unavailable")
                        MetricRow(label: "Visible Threads", value: codex.threadCount.map(String.init) ?? "Unavailable")
                        MetricRow(label: "Account", value: [codex.accountType, codex.planType].compactMap { $0 }.joined(separator: " / "))
                        MetricRow(label: "Version", value: codex.version)
                        ForEach(codex.notes, id: \.self) { note in
                            MetricRow(label: "Note", value: note, isUnavailable: true)
                        }
                    case .unavailable(let reason):
                        MetricRow(label: "Connection", value: reason, isUnavailable: true)
                    case .failed(let message):
                        MetricRow(label: "Connection", value: message, isUnavailable: true)
                    }
                }
            }
        }
    }

    private func sensorSection(_ snapshot: AdvancedSensorSnapshot) -> some View {
        MonitorSection(title: "Advanced Sensors", symbol: "sensor") {
            ModernSurface {
                VStack(spacing: 4) {
                    MetricRow(label: "CPU Temperature", value: availabilityText(snapshot.cpuTemperature) { "\($0.formatted()) C" })
                    MetricRow(label: "GPU Utilization", value: availabilityText(snapshot.gpuUsage) { percent($0) })
                    MetricRow(label: "Fan Speed", value: availabilityText(snapshot.fanSpeeds) { readings in
                        readings.map { "\($0.rpm) RPM" }.joined(separator: ", ")
                    })
                }
            }
        }
    }

    private func statusText(_ report: DiagnosticReport) -> String {
        if report.system.thermalState == .critical { return "Thermal Pressure" }
        if case .available(let memory) = report.system.memory {
            if memory.pressure == .critical { return "High Memory Pressure" }
            if memory.pressure == .warning { return "Memory Pressure Elevated" }
        }
        return "All Systems Normal"
    }

    private func cpuPercent(_ availability: Availability<CPUReading>) -> Double? {
        guard case .available(let value) = availability else { return nil }
        return value.usagePercent
    }

    private func memoryPercent(_ availability: Availability<MemoryReading>) -> Double? {
        guard case .available(let value) = availability, value.totalBytes > 0 else { return nil }
        return Double(value.usedBytes) / Double(value.totalBytes) * 100
    }

    private func storagePercent(_ availability: Availability<StorageReading>) -> Double? {
        guard case .available(let value) = availability, value.totalBytes > 0 else { return nil }
        return Double(value.usedBytes) / Double(value.totalBytes) * 100
    }

    private func storageValue(_ availability: Availability<StorageReading>) -> String {
        guard case .available(let value) = availability else { return "Unavailable" }
        return "\(bytes(value.usedBytes)) used"
    }

    private func memoryColor(_ availability: Availability<MemoryReading>) -> Color {
        guard case .available(let value) = availability else { return .secondary }
        return memoryBarColor(usage: memoryPercent(availability) ?? 0, pressure: value.pressure)
    }

    private func memoryBarColor(usage: Double, pressure: MemoryPressure) -> Color {
        pressure == .unavailable ? MetricColor.utilization(usage) : MetricColor.memoryPressure(pressure)
    }

    private func pressureValue(_ availability: Availability<MemoryReading>) -> String {
        guard case .available(let value) = availability else { return "Unavailable" }
        return "\(value.pressure.rawValue.capitalized) pressure"
    }

    private func codexDisplayWindow(
        _ availability: Availability<CodexDiagnosticSnapshot>
    ) -> CodexRateLimitWindow? {
        guard case .available(let codex) = availability else { return nil }
        return codex.menuBarLimit
    }

    private func availabilityText<Value: Sendable>(
        _ availability: Availability<Value>,
        formatter: (Value) -> String
    ) -> String {
        switch availability {
        case .available(let value): formatter(value)
        case .unavailable: "Unavailable"
        case .failed: "Failed"
        }
    }

    private func percent(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...1))))%"
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    private func rate(_ value: Double) -> String {
        "\((value * 8 / 1_000_000).formatted(.number.precision(.fractionLength(1)))) Mbps"
    }

    private func formatCount(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }
}

struct MenuBarPanel: View {
    private enum AgentPane: String, CaseIterable {
        case codex
        case cursor

        var title: String {
            switch self {
            case .codex: return "CODEX"
            case .cursor: return "CURSOR"
            }
        }

        var symbol: String {
            switch self {
            case .codex: return "terminal"
            case .cursor: return "arrow.triangle.2.circlepath.circle"
            }
        }
    }

    @EnvironmentObject private var model: DiagnosticViewModel
    @State private var presentationID = UUID()
    @State private var agentPane: AgentPane = .codex

    private let panelWidth: CGFloat = 332
    private let maxPanelHeight: CGFloat = 460

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)

            Group {
                if ReadmeAssetCapture.isRequested {
                    panelContent
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        panelContent
                    }
                }
            }
        }
        .frame(width: panelWidth)
        .frame(maxHeight: ReadmeAssetCapture.isRequested ? .infinity : maxPanelHeight)
        .fixedSize(horizontal: true, vertical: ReadmeAssetCapture.isRequested)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .onAppear { model.setPresentation(presentationID, isActive: true) }
        .onDisappear { model.setPresentation(presentationID, isActive: false) }
    }

    @ViewBuilder
    private var panelContent: some View {
        VStack(spacing: 8) {
            if model.slowdown.severity != .none {
                slowdownBanner
            }

            if let report = model.report {
                metricGrid(report)
                actionRow
            } else {
                ProgressView("Collecting…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("~")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(panelStatusColor)
                .frame(width: 22, height: 22)
                .background(Circle().fill(panelStatusColor.opacity(0.16)))
            VStack(alignment: .leading, spacing: 0) {
                Text("Tilde")
                    .font(.subheadline.weight(.semibold))
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if model.runState == .running {
                ProgressView()
                    .controlSize(.mini)
            }
        }
    }

    private var slowdownBanner: some View {
        let advice = model.slowdown
        let tint: Color = advice.severity == .critical ? .red : .orange
        return HStack(spacing: 6) {
            Image(systemName: advice.severity == .critical ? "exclamationmark.triangle.fill" : "thermometer.medium")
                .font(.caption2)
                .foregroundStyle(tint)
            Text(advice.title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }

    @ViewBuilder
    private func metricGrid(_ report: DiagnosticReport) -> some View {
        let decisions = model.decisionQueue.needsYouItems

        VStack(spacing: 8) {
            if decisions.isEmpty {
                decisionSection(model.decisionQueue.topItem)

                if model.agentAttention.providerAvailable,
                   !model.agentAttention.agents.isEmpty {
                    attentionCard
                }
                if model.verification.state != .dismissed {
                    verificationCard
                }

                HStack(alignment: .top, spacing: 8) {
                    cpuCard(report)
                    memoryCard(report)
                }
                HStack(alignment: .top, spacing: 8) {
                    fanCard
                    VStack(spacing: 8) {
                        storageCard(report)
                        networkCard(report.system.network)
                    }
                }
                agentCard(report)
                contextStrip
                focusStrip
            } else {
                ForEach(Array(decisions.enumerated()), id: \.element.id) { index, item in
                    if index == 0 {
                        decisionCard(item)
                    } else {
                        compactDecisionCard(item)
                    }
                }
                decisionActivityStrip
            }
        }
    }

    @ViewBuilder
    private func decisionSection(_ item: DecisionQueueItem?) -> some View {
        if let item, item.needsYou {
            decisionCard(item)
        } else if let item {
            decisionIdleStrip(item)
        } else {
            decisionEmptyStrip
        }
    }

    private func decisionCard(_ item: DecisionQueueItem) -> some View {
        let tint = decisionTint(item)
        return ControlCenterCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Needs you")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(tint.opacity(0.14))
                        )
                    Spacer(minLength: 4)
                    Text(item.subtitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.projectName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(item.branch.map { "branch \($0)" } ?? "detached HEAD")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(item.reasons) { reason in
                        HStack(alignment: .top, spacing: 7) {
                            Text(reasonGlyph(reason.severity))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(reasonColor(reason.severity))
                                .frame(width: 12, alignment: .center)
                            Text(reason.message)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let primary = item.primaryAction {
                    Button {
                        model.performDecisionAction(primary, for: item)
                    } label: {
                        Text(primary.title)
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundStyle(.white)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(tint)
                            )
                    }
                    .buttonStyle(.plain)

                    if !item.secondaryActions.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(item.secondaryActions) { action in
                                Button {
                                    model.performDecisionAction(action, for: item)
                                } label: {
                                    Text(action.title)
                                        .font(.caption2.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .foregroundStyle(.primary)
                                        .background(
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .fill(Color.primary.opacity(0.06))
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private func compactDecisionCard(_ item: DecisionQueueItem) -> some View {
        let tint = decisionTint(item)
        return ControlCenterCard {
            HStack(spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.projectName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(item.reasons.first?.message ?? item.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let primary = item.primaryAction {
                    Button(primary.title) {
                        model.performDecisionAction(primary, for: item)
                    }
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(tint)
                }
            }
        }
    }

    private var decisionActivityStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "ellipsis.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(model.decisionQueue.workingCount) working · \(model.decisionQueue.idleCount) idle")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text("\(model.decisionQueue.items.count) changes")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
    }

    private func decisionIdleStrip(_ item: DecisionQueueItem) -> some View {
        ControlCenterCard {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nothing needs you")
                        .font(.caption.weight(.semibold))
                    Text("\(item.projectName) · \(item.subtitle)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let primary = item.primaryAction {
                    Button(primary.title) {
                        model.performDecisionAction(primary, for: item)
                    }
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var decisionEmptyStrip: some View {
        ControlCenterCard {
            HStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("No active change yet")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
            }
        }
    }

    private func decisionTint(_ item: DecisionQueueItem) -> Color {
        if item.reasons.contains(where: { $0.severity == .fail }) { return .red }
        if item.needsYou { return .orange }
        return .accentColor
    }

    private func reasonGlyph(_ severity: DecisionSeverity) -> String {
        switch severity {
        case .pass: return "✓"
        case .warn, .fail: return "!"
        case .info: return "·"
        }
    }

    private func reasonColor(_ severity: DecisionSeverity) -> Color {
        switch severity {
        case .pass: return .green
        case .warn: return .orange
        case .fail: return .red
        case .info: return .secondary
        }
    }

    private var attentionCard: some View {
        let attention = model.agentAttention.attentionItems
        let available = model.agentAttention.displayItems
        let visible = Array(available.prefix(4))

        return ControlCenterCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: attention.isEmpty ? "sparkles" : "exclamationmark.bubble.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(attention.isEmpty ? Color.secondary : Color.orange)
                    Text(attention.isEmpty ? "AGENTS · AVAILABLE" : "AGENTS · NEED YOU")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.agentAttention.agents.count)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ForEach(visible) { agent in
                    Button {
                        model.focusAgent(agent)
                    } label: {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(agentStateColor(agent.state))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(agent.projectName) · \(agent.agent.capitalized)")
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text(agent.branch.map { "\(agent.state.label) · \($0)" } ?? agent.state.label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "arrow.up.forward.app")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Focus this agent in Herdr")
                }

                if available.count > visible.count {
                    Text("+\(available.count - visible.count) more available")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var verificationCard: some View {
        let snapshot = model.verification
        let tint = verificationTint(snapshot.state)
        return ControlCenterCard {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: verificationSymbol(snapshot.state))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint)
                    Text("EXACT VERIFICATION")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(snapshot.state.label.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(tint)
                }

                Text(snapshot.summary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                if let message = snapshot.message,
                   snapshot.state != .unavailable {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .help(message)
                }

                if let changeSet = snapshot.changeSet {
                    Text("\(changeSet.baseRef) · fingerprint \(changeSet.fingerprint.shortValue)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if snapshot.state == .stale,
                   let record = snapshot.record {
                    Text("Previous proof · \(record.fingerprint.shortValue) · head \(record.headOID.prefix(8))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if snapshot.state == .untrusted,
                   let checks = snapshot.loadedProfile?.profile.checks {
                    Text("Review these repository commands before allowing execution:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(checks) { check in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(check.name)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                            Text("$ \(check.command)")
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !snapshot.receipts.isEmpty,
                   snapshot.state != .stale {
                    ForEach(snapshot.receipts) { receipt in
                        HStack(spacing: 5) {
                            Image(systemName: receipt.outcome == .passed
                                  ? "checkmark.circle.fill"
                                  : "xmark.circle.fill")
                                .foregroundStyle(receipt.outcome == .passed ? Color.green : Color.red)
                            Text(receipt.checkName)
                            Spacer(minLength: 4)
                            Text("\(receipt.duration.formatted(.number.precision(.fractionLength(1))))s")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption2)
                    }
                }

                if let output = snapshot.outputExcerpt,
                   snapshot.state == .failed || snapshot.state == .partial {
                    Text(output)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(output)
                }

                verificationAction(snapshot)
            }
        }
    }

    @ViewBuilder
    private func verificationAction(_ snapshot: VerificationSnapshot) -> some View {
        switch snapshot.state {
        case .untrusted:
            Button("Trust & Run \(snapshot.loadedProfile?.profile.checks.count ?? 0) Commands") {
                model.runVerification(trustingProfile: true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Trust this exact repository and profile hash, then run the commands shown above")
        case .missing:
            Button("Run Required Checks") {
                model.runVerification()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .failed, .partial, .stale:
            HStack(spacing: 6) {
                Button(snapshot.state == .stale ? "Run for Current Change" : "Run Required Checks") {
                    model.runVerification()
                }
                .buttonStyle(.borderedProminent)
                Button("Clear & Hide") {
                    model.clearVerificationResult()
                }
                .buttonStyle(.bordered)
                .help("Delete this worktree's receipt and hide the card until the change moves")
            }
            .controlSize(.small)
        case .verified:
            HStack(spacing: 6) {
                Button("Run Again") {
                    model.runVerification()
                }
                .buttonStyle(.bordered)
                Button("Clear & Hide") {
                    model.clearVerificationResult()
                }
                .buttonStyle(.bordered)
                .help("Delete this worktree's receipt and hide the card until the change moves")
            }
            .controlSize(.small)
        case .running:
            Button("Cancel Checks", role: .cancel) {
                model.cancelVerification()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .unavailable, .unconfigured, .dismissed:
            EmptyView()
        }
    }

    private func verificationTint(_ state: VerificationState) -> Color {
        switch state {
        case .verified: return .green
        case .running: return .blue
        case .failed: return .red
        case .stale, .untrusted, .missing, .partial: return .orange
        case .unavailable, .unconfigured, .dismissed: return .secondary
        }
    }

    private func verificationSymbol(_ state: VerificationState) -> String {
        switch state {
        case .verified: return "checkmark.seal.fill"
        case .running: return "clock.badge.checkmark"
        case .failed: return "xmark.seal.fill"
        case .stale: return "clock.badge.exclamationmark"
        case .untrusted: return "lock.shield"
        case .missing, .partial: return "exclamationmark.shield"
        case .unavailable, .unconfigured, .dismissed: return "shield"
        }
    }

    private func agentStateColor(_ state: AgentAttentionState) -> Color {
        switch state {
        case .blocked: return .orange
        case .done: return .green
        case .working: return .blue
        case .idle: return .secondary
        case .unknown: return .gray
        }
    }

    private func cpuCard(_ report: DiagnosticReport) -> some View {
        let cpuPercent: Double? = {
            if case .available(let cpu) = report.system.cpu { return cpu.usagePercent }
            return nil
        }()
        let tint = MetricColor.utilization(cpuPercent ?? 0)

        return ControlCenterCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("CPU")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)

                if let cpuPercent {
                    Text(percent(cpuPercent))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)

                    CompactCPUSparkline(samples: model.history, tint: tint)
                        .frame(height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                    ColorBar(fraction: cpuPercent / 100, color: tint)
                } else {
                    Text("—")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                        .frame(height: 28)
                    ColorBar(fraction: 0, color: .secondary)
                }
            }
        }
    }

    private func memoryCard(_ report: DiagnosticReport) -> some View {
        ControlCenterCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("RAM")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                if case .available(let memory) = report.system.memory, memory.totalBytes > 0 {
                    let usage = Double(memory.usedBytes) / Double(memory.totalBytes)
                    let tint = memory.pressure == .unavailable
                        ? MetricColor.utilization(usage * 100)
                        : MetricColor.memoryPressure(memory.pressure)

                    Text(percent(usage * 100))
                        .font(.title3.weight(.semibold).monospacedDigit())

                    Text("\(bytes(memory.usedBytes)) / \(bytes(memory.totalBytes))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(height: 28, alignment: .center)

                    ColorBar(fraction: usage, color: tint)
                } else {
                    Text("—")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Color.clear.frame(height: 28)
                    ColorBar(fraction: 0, color: .secondary)
                }
            }
        }
    }

    private func storageCard(_ report: DiagnosticReport) -> some View {
        ControlCenterCard {
            VStack(alignment: .leading, spacing: 3) {
                Text("DISK")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                if case .available(let storage) = report.system.storage, storage.totalBytes > 0 {
                    let usage = Double(storage.usedBytes) / Double(storage.totalBytes)
                    Text(percent(usage * 100))
                        .font(.callout.weight(.semibold).monospacedDigit())
                    ColorBar(fraction: usage, color: .blue)
                } else {
                    Text("—")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func agentCard(_ report: DiagnosticReport) -> some View {
        let spend = DailyAISpendSummary(
            codex: report.codex.availableValue?.dailySpend,
            cursor: report.cursor.availableValue?.dailySpend
        )
        return ControlCenterCard {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("AI SPEND · TODAY")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(spend.knownTotalCents.map {
                        "\(spend.containsEstimate ? "≈" : "")\(DailyAISpendSummary.usd($0))"
                    } ?? "$—")
                        .font(.title3.weight(.semibold).monospacedDigit())
                }
                Text(spend.detailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if spend.containsEstimate {
                    Text("Estimate · official credit rates + local token mix")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if !spend.hasCompleteProviderCoverage, spend.knownTotalCents != nil {
                    Text("Lower bound · missing provider or pre-tracking spend")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Divider()

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        agentPane = agentPane == .codex ? .cursor : .codex
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: agentPane.symbol)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("LIMITS · \(agentPane.title)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        if agentPane == .cursor,
                           case .available(let cursor) = report.cursor,
                           let plan = cursor.planName {
                            Text(plan.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .help("Tap to switch Codex / Cursor")

                switch agentPane {
                case .codex:
                    if case .available(let codex) = report.codex {
                        codexWindowSummary(codex)
                    } else {
                        agentRemaining(percent: nil, detail: "Codex unavailable")
                    }
                case .cursor:
                    agentRemaining(
                        percent: {
                            if case .available(let cursor) = report.cursor {
                                return cursor.remainingPercent
                            }
                            return nil
                        }(),
                        detail: {
                            if case .available(let cursor) = report.cursor {
                                return cursor.displayMessage ?? "Remaining allowance"
                            }
                            return "Sign in to Cursor"
                        }()
                    )
                }
            }
        }
    }

    private func agentRemaining(percent: Int?, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(percent.map { "\($0)%" } ?? "—")
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text("left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let percent {
                ColorBar(fraction: Double(percent) / 100, color: MetricColor.remaining(percent))
            }
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func codexWindowSummary(_ codex: CodexDiagnosticSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            compactCodexWindow(label: "5h", window: codex.fiveHourLimit)
            compactCodexWindow(label: "7d", window: codex.weeklyLimit)
            if codex.fiveHourLimit == nil,
               codex.weeklyLimit == nil,
               let other = codex.rateLimitWindows.first {
                compactCodexWindow(label: codexWindowLabel(other), window: other)
            }
            Text("Today \(codex.tokensToday.map(compactCount) ?? "—") tokens")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func compactCodexWindow(label: String, window: CodexRateLimitWindow?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .leading)
                Text(window.map { "\($0.remainingPercent)% left" } ?? "Not reported")
                    .font(.caption.weight(.semibold).monospacedDigit())
                Spacer(minLength: 4)
                if let reset = window?.resetsAt {
                    Text("↻ \(compactCodexReset(reset))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if let window {
                ColorBar(
                    fraction: Double(window.remainingPercent) / 100,
                    color: MetricColor.remaining(window.remainingPercent)
                )
            }
        }
    }

    private var contextStrip: some View {
        ControlCenterCard {
            VStack(alignment: .leading, spacing: 4) {
                compactRow(
                    symbol: model.buildPulse.phase == .running ? "hammer.fill" : "hammer",
                    label: "Build",
                    value: model.buildPulse.statusText,
                    tint: model.buildPulse.phase == .running ? .orange : .secondary
                )
                compactRow(
                    symbol: "folder",
                    label: "Project",
                    value: model.projectContext.hasProject
                        ? "\(model.projectContext.projectName ?? "Repo") · \(model.projectContext.chipText)"
                        : "No project",
                    tint: .secondary
                )
                compactRow(
                    symbol: trustSymbol,
                    label: "Trust",
                    value: model.trustPacket.summary,
                    tint: trustTint
                )
                if let risk = model.trustPacket.risks.first {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(risk.message)
                            .lineLimit(2)
                        if model.trustPacket.risks.count > 1 {
                            Text("+\(model.trustPacket.risks.count - 1)")
                                .fontWeight(.bold)
                                .accessibilityLabel(
                                    "\(model.trustPacket.risks.count - 1) more checks"
                                )
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(trustTint)
                    .padding(.leading, 64)
                }
                compactRow(
                    symbol: "book.closed",
                    label: "Today",
                    value: model.todaySummary.headline,
                    tint: .secondary
                )
                if let capsule = model.recoveryCapsule {
                    compactRow(
                        symbol: "arrow.uturn.backward.circle",
                        label: "Resume",
                        value: capsule.headline,
                        tint: capsule.attentionCount > 0 ? .orange : .secondary
                    )
                }
            }
        }
    }

    private var trustSymbol: String {
        switch model.trustPacket.state {
        case .unavailable: return "checkmark.shield"
        case .verifying: return "clock.badge.checkmark"
        case .needsVerification: return "exclamationmark.shield"
        case .ready: return "checkmark.shield.fill"
        }
    }

    private var trustTint: Color {
        switch model.trustPacket.state {
        case .unavailable: return .secondary
        case .verifying: return .blue
        case .needsVerification: return .orange
        case .ready: return .green
        }
    }

    private func compactRow(symbol: String, label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 12)
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            Text(value)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var focusStrip: some View {
        ControlCenterCard {
            HStack(spacing: 6) {
                Text("FOCUS")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                ForEach([FocusMode.ship, .meet, .battery], id: \.self) { mode in
                    let selected = model.focusMode == mode
                    Button {
                        model.applyFocusMode(selected ? .off : mode)
                    } label: {
                        Text(mode.title)
                            .font(.caption2.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func networkCard(_ availability: Availability<NetworkReading>) -> some View {
        ControlCenterCard {
            VStack(alignment: .leading, spacing: 3) {
                Text("NET")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                if case .available(let network) = availability {
                    Text("↓ \(network.downloadBytesPerSecond.map(rate) ?? "—")")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.blue)
                    Text("↑ \(network.uploadBytesPerSecond.map(rate) ?? "—")")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.orange)
                } else {
                    Text("—")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var fanCard: some View {
        let isActive = model.fanBoost.isActivelyBoosting
        let isPending = model.fanBoost.isPending
        return ControlCenterCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("FAN")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isActive ? Color.green : Color.secondary)
                    Spacer(minLength: 2)
                    Toggle("", isOn: Binding(
                        get: { model.isFanBoostEnabled },
                        set: { model.setFanBoostEnabled($0) }
                    ))
                    .toggleStyle(FanBoostToggleStyle())
                    .labelsHidden()
                    .disabled(isPending)
                    .accessibilityLabel("Fan Boost")
                }

                FanWindAnimationView(isRunning: isActive)
                    .scaleEffect(0.78)
                    .frame(height: 40)

                HStack {
                    Text("\(model.fanBoost.speedPercent)%")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(isActive ? Color.green : Color.primary)
                    Slider(
                        value: Binding(
                            get: { model.fanBoost.speed },
                            set: { model.setFanBoostSpeed($0) }
                        ),
                        in: 0.15...1.0
                    )
                    .tint(isActive ? Color(red: 0.22, green: 0.78, blue: 0.38) : Color.secondary.opacity(0.7))
                    .disabled(isPending)
                    .controlSize(.mini)
                }
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            ControlCenterAction(
                title: "Open",
                systemImage: "macwindow",
                tint: .blue
            ) {
                NotificationCenter.default.post(name: .tildeOpenMainWindow, object: nil)
            }

            ControlCenterAction(
                title: "Copy",
                systemImage: "doc.on.doc",
                tint: .primary
            ) {
                model.copyStatusToPasteboard()
            }

            ControlCenterAction(
                title: "Refresh",
                systemImage: "arrow.clockwise",
                tint: .primary,
                disabled: model.runState == .running
            ) {
                model.refresh()
            }

            ControlCenterAction(
                title: "Quit",
                systemImage: "power",
                tint: .red
            ) {
                NSApp.terminate(nil)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var statusText: String {
        if model.runState == .running { return "Monitoring" }
        if let decision = model.decisionQueue.topItem, decision.needsYou {
            return decision.subtitle
        }
        switch model.verification.state {
        case .failed: return "Exact verification failed"
        case .stale: return "Verification evidence is stale"
        case .running: return "Running exact verification"
        case .untrusted: return "Review verification profile"
        default: break
        }
        if model.agentAttention.attentionCount > 0 {
            let count = model.agentAttention.attentionCount
            return "\(count) agent\(count == 1 ? " needs" : "s need") you"
        }
        guard let report = model.report else { return "Starting" }
        if report.system.thermalState == .critical { return "Thermal Pressure" }
        if case .available(let memory) = report.system.memory {
            if memory.pressure == .critical { return "High Memory Pressure" }
            if memory.pressure == .warning { return "Memory Pressure Elevated" }
        }
        return "All Systems Normal"
    }

    private var panelStatusColor: Color {
        if model.verification.state == .failed { return .red }
        if model.verification.state == .stale || model.verification.state == .untrusted {
            return .orange
        }
        if model.verification.state == .running { return .blue }
        if model.verification.state == .verified { return .green }
        if model.agentAttention.attentionCount > 0 { return .orange }
        guard let report = model.report else { return .secondary }
        if report.system.thermalState == .critical { return .red }
        if case .available(let memory) = report.system.memory {
            return MetricColor.memoryPressure(memory.pressure)
        }
        return .green
    }

    private func percent(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...1))))%"
    }

    private func rate(_ bytesPerSecond: Double) -> String {
        "\((bytesPerSecond * 8 / 1_000_000).formatted(.number.precision(.fractionLength(1)))) Mbps"
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    private func compactCount(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }
}

private func codexWindowOrder(_ kind: CodexRateLimitKind) -> Int {
    switch kind {
    case .fiveHour: return 0
    case .weekly: return 1
    case .other: return 2
    }
}

private func codexWindowLabel(_ window: CodexRateLimitWindow) -> String {
    if window.kind != .other { return window.kind.label }
    guard let minutes = window.durationMinutes else { return window.kind.label }
    if minutes.isMultiple(of: 1_440) { return "\(minutes / 1_440)-day window" }
    if minutes.isMultiple(of: 60) { return "\(minutes / 60)-hour window" }
    return "\(minutes)-minute window"
}

private func compactCodexReset(_ reset: Date, calendar: Calendar = .current) -> String {
    if calendar.isDateInToday(reset) {
        return reset.formatted(date: .omitted, time: .shortened)
    }
    return reset.formatted(date: .abbreviated, time: .omitted)
}

private struct ControlCenterCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            }
    }
}

private struct ControlCenterAction: View {
    let title: String
    let systemImage: String
    var tint: Color = .primary
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 44, height: 44)
                    Image(systemName: systemImage)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(disabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint))
                }
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(title)
    }
}

private struct MetricRow: View {
    let label: String
    let value: String
    var isUnavailable = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 24)
            Text(value.isEmpty ? "Unavailable" : value)
                .foregroundStyle(isUnavailable || value.isEmpty ? .secondary : .primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
        .padding(.vertical, 5)
    }
}
