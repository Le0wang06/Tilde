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
            MenuBarStatusItemController.shared.install(model: model)
        }
    }

    var body: some Scene {
        WindowGroup("Tilde", id: "diagnostics") {
            DiagnosticContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 560)
        }
        .defaultSize(width: 920, height: 780)
        // Menu bar item is an AppKit NSStatusItem so the AI % text is always visible.
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
    /// Compact Codex remaining % shown in the macOS menu bar title.
    @Published private(set) var menuBarTitle: String = "~ …"
    @Published private(set) var fanBoost: FanBoostController.Snapshot = .idle
    @Published private(set) var buildPulse = BuildPulseSnapshot()
    @Published private(set) var slowdown = SlowdownAdvice.none
    @Published private(set) var projectContext = ProjectContextSnapshot.empty
    @Published private(set) var focusMode: FocusMode = .off
    @Published private(set) var todaySummary = SessionDiaryTodaySummary.empty
    private let liveMonitoring = LiveMonitoringService()
    private let fanBoostController = FanBoostController()
    private let buildPulseMonitor = BuildPulseMonitor()
    private let projectContextMonitor = ProjectContextMonitor()
    private let slowdownNotifier = SlowdownNotifier()
    private let sessionDiary = SessionDiaryStore()
    private var historyBuffer = LiveMetricHistory()
    private var subscriptionTask: Task<Void, Never>?
    private var buildPulseTask: Task<Void, Never>?
    private var projectContextTask: Task<Void, Never>?
    private var speedWriteTask: Task<Void, Never>?
    private var didAskNotificationAuth = false
    private var didRecordAppStart = false
    private var lastLoggedBuildPhase: BuildPulsePhase = .idle
    private var lastLoggedSlowdown: SlowdownSeverity = .none
    private let menuBarPresentationID = UUID()

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
                let snapshot = await self.projectContextMonitor.snapshot()
                self.projectContext = snapshot
                if let report = self.report {
                    self.publishMenuBarTitle(
                        codex: report.codex,
                        cursor: report.cursor,
                        build: self.buildPulse,
                        slowdown: self.slowdown,
                        project: snapshot,
                        focus: self.focusMode
                    )
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func apply(report: DiagnosticReport) {
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
        menuBarTitle = Self.makeMenuBarTitle(
            from: codex,
            cursor: cursor,
            build: build,
            slowdown: slowdown,
            project: project,
            focus: focus
        )
        MenuBarStatusItemController.shared.updateTitle(menuBarTitle)
        NotificationCenter.default.post(
            name: .tildeMenuBarTitleDidChange,
            object: nil,
            userInfo: ["title": menuBarTitle]
        )
    }

    private static func makeMenuBarTitle(
        from codex: Availability<CodexDiagnosticSnapshot>,
        cursor: Availability<CursorUsageSnapshot>,
        build: BuildPulseSnapshot,
        slowdown: SlowdownAdvice,
        project: ProjectContextSnapshot,
        focus: FocusMode
    ) -> String {
        let cx: String
        if case .available(let snapshot) = codex, let remaining = snapshot.primaryLimit?.remainingPercent {
            cx = "\(remaining)%"
        } else {
            cx = "—"
        }

        let cr: String
        if case .available(let snapshot) = cursor, let remaining = snapshot.remainingPercent {
            cr = "\(remaining)%"
        } else {
            cr = "—"
        }

        var title = "~ Cx \(cx) · Cr \(cr)"
        if build.phase == .running {
            title += " · ⚒"
        } else if build.phase == .finished {
            title += " · ✓"
        }
        switch slowdown.severity {
        case .critical:
            title += " · !!"
        case .warn:
            title += " · !"
        case .none:
            break
        }
        if let branch = project.branch {
            let short = branch.count > 16 ? String(branch.prefix(14)) + "…" : branch
            title += " · \(short)\(project.isDirty ? "*" : "")"
        }
        if focus != .off {
            title += " · \(focus.title)"
        }
        return title
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
        HStack(spacing: 10) {
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
                value: codexRemaining(report.codex).map { "\($0)%" } ?? "--",
                detail: "Allowance remaining",
                color: codexRemaining(report.codex).map(MetricColor.remaining) ?? .secondary,
                fraction: codexRemaining(report.codex).map { Double($0) / 100 }
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
                        if let primary = codex.primaryLimit {
                            MetricBar(
                                label: "Current Window",
                                value: "\(primary.remainingPercent)% remaining",
                                fraction: Double(primary.remainingPercent) / 100,
                                color: MetricColor.remaining(primary.remainingPercent),
                                detail: primary.resetsAt.map { "Resets \($0.formatted(date: .omitted, time: .shortened))" }
                            )
                        }
                        if let secondary = codex.secondaryLimit {
                            MetricBar(
                                label: "Secondary Window",
                                value: "\(secondary.remainingPercent)% remaining",
                                fraction: Double(secondary.remainingPercent) / 100,
                                color: MetricColor.remaining(secondary.remainingPercent)
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

    private func codexRemaining(_ availability: Availability<CodexDiagnosticSnapshot>) -> Int? {
        guard case .available(let codex) = availability else { return nil }
        return codex.primaryLimit?.remainingPercent
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
    @EnvironmentObject private var model: DiagnosticViewModel
    @State private var presentationID = UUID()
    @Environment(\.colorScheme) private var colorScheme

    private let panelWidth: CGFloat = 360

    var body: some View {
        VStack(spacing: 10) {
            header
            if model.slowdown.severity != .none {
                slowdownBanner
            }

            if let report = model.report {
                metricGrid(report)
                actionRow
                footerBar
            } else {
                ProgressView("Collecting…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(12)
        .frame(width: panelWidth)
        .fixedSize(horizontal: true, vertical: true)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .onAppear { model.setPresentation(presentationID, isActive: true) }
        .onDisappear { model.setPresentation(presentationID, isActive: false) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(panelStatusColor.opacity(0.18))
                    .frame(width: 28, height: 28)
                Text("~")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(panelStatusColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Tilde")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if model.runState == .running {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private var slowdownBanner: some View {
        let advice = model.slowdown
        let tint: Color = advice.severity == .critical ? .red : .orange
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: advice.severity == .critical ? "exclamationmark.triangle.fill" : "thermometer.medium")
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(advice.title)
                    .font(.caption.weight(.semibold))
                Text(advice.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }

    @ViewBuilder
    private func metricGrid(_ report: DiagnosticReport) -> some View {
        // Two independent columns avoid Grid row height matching, which left
        // empty space under the shorter CPU card before FAN started.
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 10) {
                    cpuCard(report)
                    fanCard
                }
                .frame(maxWidth: .infinity, alignment: .top)

                VStack(spacing: 10) {
                    memoryCard(report)
                    storageCard(report)
                    networkCard(report.system.network)
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }

            codexCard(report)
            cursorCard(report)
            buildPulseCard
            projectCard
            focusModeCard
            todayCard
        }
    }

    private func cpuCard(_ report: DiagnosticReport) -> some View {
        ControlCenterCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("CPU")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(cpuPercentText(report))
                        .font(.caption.weight(.semibold).monospacedDigit())
                }

                LiveResourceChart(samples: model.history, compact: true)
                    .frame(height: 72)

                if case .available(let cpu) = report.system.cpu {
                    ColorBar(fraction: cpu.usagePercent / 100, color: .blue)
                }
            }
        }
    }

    private func memoryCard(_ report: DiagnosticReport) -> some View {
        ControlCenterCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "memorychip")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("RAM")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                if case .available(let memory) = report.system.memory, memory.totalBytes > 0 {
                    let usage = Double(memory.usedBytes) / Double(memory.totalBytes)
                    Text(percent(usage * 100))
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Text("U: \(bytes(memory.usedBytes))  T: \(bytes(memory.totalBytes))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    ColorBar(
                        fraction: usage,
                        color: memory.pressure == .unavailable
                            ? .blue
                            : MetricColor.memoryPressure(memory.pressure)
                    )
                } else {
                    Text("—")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func storageCard(_ report: DiagnosticReport) -> some View {
        ControlCenterCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("DISK")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                if case .available(let storage) = report.system.storage, storage.totalBytes > 0 {
                    let usage = Double(storage.usedBytes) / Double(storage.totalBytes)
                    Text(percent(usage * 100))
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Text("U: \(bytes(storage.usedBytes))  T: \(bytes(storage.totalBytes))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    ColorBar(fraction: usage, color: .blue)
                } else {
                    Text("—")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func codexCard(_ report: DiagnosticReport) -> some View {
        ControlCenterCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("CODEX")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                if case .available(let codex) = report.codex {
                    let remaining = codex.primaryLimit?.remainingPercent
                    Text(remaining.map { "\($0)%" } ?? "—")
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Text("Remaining")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let remaining {
                        ColorBar(fraction: Double(remaining) / 100, color: MetricColor.remaining(remaining))
                    }
                    Text("Today \(codex.tokensToday.map(compactCount) ?? "—") tokens")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                } else {
                    Text("—")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Unavailable")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func cursorCard(_ report: DiagnosticReport) -> some View {
        ControlCenterCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("CURSOR")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if case .available(let cursor) = report.cursor, let plan = cursor.planName {
                        Text(plan.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                if case .available(let cursor) = report.cursor {
                    Text(cursor.remainingPercent.map { "\($0)%" } ?? "—")
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Text("Remaining")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let remaining = cursor.remainingPercent {
                        ColorBar(fraction: Double(remaining) / 100, color: MetricColor.remaining(remaining))
                    }
                    if let message = cursor.displayMessage {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                } else {
                    Text("—")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Sign in to Cursor to show usage")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var buildPulseCard: some View {
        let pulse = model.buildPulse
        return ControlCenterCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: pulse.phase == .running ? "hammer.fill" : "hammer")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(pulse.phase == .running ? Color.orange : Color.secondary)
                    Text("BUILD")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(pulse.phase == .running ? Color.orange : Color.secondary)
                    Spacer()
                    if pulse.phase == .running {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                Text(pulse.statusText)
                    .font(.caption.weight(.semibold))
                if let summary = pulse.commandSummary {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var projectCard: some View {
        let project = model.projectContext
        let ciTint: Color = {
            switch project.ciStatus {
            case .success: return .green
            case .failure: return .red
            case .pending: return .orange
            case .cancelled, .unknown: return .secondary
            }
        }()
        return ControlCenterCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("PROJECT")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if project.ciStatus != .unknown {
                        Text(project.ciStatus.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(ciTint)
                    }
                }
                Text(project.chipText)
                    .font(.caption.weight(.semibold).monospacedDigit())
                Text(project.detailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var focusModeCard: some View {
        ControlCenterCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "target")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("FOCUS")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    ForEach([FocusMode.ship, .meet, .battery], id: \.self) { mode in
                        let selected = model.focusMode == mode
                        Button {
                            model.applyFocusMode(selected ? .off : mode)
                        } label: {
                            Text(mode.title)
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(model.focusMode.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var todayCard: some View {
        let today = model.todaySummary
        return ControlCenterCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "book.closed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("TODAY")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Text(today.headline)
                    .font(.caption.weight(.semibold))
                Text(today.detailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func networkCard(_ availability: Availability<NetworkReading>) -> some View {
        ControlCenterCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "network")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("NETWORK")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                if case .available(let network) = availability {
                    HStack(spacing: 12) {
                        Label(network.downloadBytesPerSecond.map(rate) ?? "—", systemImage: "arrow.down")
                            .foregroundStyle(.blue)
                        Label(network.uploadBytesPerSecond.map(rate) ?? "—", systemImage: "arrow.up")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption.weight(.semibold).monospacedDigit())

                    Text(network.localIPAddress ?? network.interfaceName ?? "Offline")
                        .font(.caption2)
                        .foregroundStyle(.blue.opacity(0.9))
                        .padding(.top, 4)
                } else {
                    Text("Unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var fanCard: some View {
        let isActive = model.fanBoost.isActivelyBoosting
        let isPending = model.fanBoost.isPending
        return ControlCenterCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "fan")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isActive ? Color.green : Color.secondary)
                    Text("FAN")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isActive ? Color.green : Color.secondary)
                    Spacer(minLength: 4)
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

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Min")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(model.fanBoost.speedPercent)%")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(isActive ? Color.green : Color.primary)
                        Spacer()
                        Text("Max")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { model.fanBoost.speed },
                            set: { model.setFanBoostSpeed($0) }
                        ),
                        in: 0.15...1.0
                    )
                    .tint(isActive ? Color(red: 0.22, green: 0.78, blue: 0.38) : Color.secondary.opacity(0.7))
                    .disabled(isPending)
                    .controlSize(.small)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if isPending {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Text(model.fanBoost.statusText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isActive ? Color.green : Color.primary)
                    }
                    Text(model.fanBoost.detailText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 14) {
            ControlCenterAction(
                title: "Open",
                systemImage: "macwindow",
                tint: .blue
            ) {
                NotificationCenter.default.post(name: .tildeOpenMainWindow, object: nil)
            }

            ControlCenterAction(
                title: "Cursor",
                systemImage: "chevron.left.forwardslash.chevron.right",
                tint: .purple
            ) {
                model.openCursor()
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
        .padding(.top, 4)
    }

    private var footerBar: some View {
        HStack {
            Text(model.menuBarTitle)
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "ellipsis")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06))
        }
    }

    private var statusText: String {
        if model.runState == .running { return "Monitoring" }
        guard let report = model.report else { return "Starting" }
        if report.system.thermalState == .critical { return "Thermal Pressure" }
        if case .available(let memory) = report.system.memory {
            if memory.pressure == .critical { return "High Memory Pressure" }
            if memory.pressure == .warning { return "Memory Pressure Elevated" }
        }
        return "All Systems Normal"
    }

    private var panelStatusColor: Color {
        guard let report = model.report else { return .secondary }
        if report.system.thermalState == .critical { return .red }
        if case .available(let memory) = report.system.memory {
            return MetricColor.memoryPressure(memory.pressure)
        }
        return .green
    }

    private func cpuPercentText(_ report: DiagnosticReport) -> String {
        if case .available(let cpu) = report.system.cpu {
            return percent(cpu.usagePercent)
        }
        return "—"
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

private struct ControlCenterCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
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
