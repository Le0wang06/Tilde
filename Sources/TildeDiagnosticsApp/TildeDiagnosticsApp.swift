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
    private let liveMonitoring = LiveMonitoringService()
    private let fanBoostController = FanBoostController()
    private var historyBuffer = LiveMetricHistory()
    private var subscriptionTask: Task<Void, Never>?
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
        }
        subscriptionTask = Task { [weak self] in
            guard let self else { return }
            let reports = await liveMonitoring.reports()
            for await report in reports {
                guard !Task.isCancelled else { break }
                self.apply(report: report)
            }
        }
    }

    private func apply(report: DiagnosticReport) {
        self.report = report
        historyBuffer.append(LiveMetricSample(snapshot: report.system))
        history = historyBuffer.samples
        menuBarTitle = Self.makeMenuBarTitle(from: report.codex)
        MenuBarStatusItemController.shared.updateTitle(menuBarTitle)
        NotificationCenter.default.post(
            name: .tildeMenuBarTitleDidChange,
            object: nil,
            userInfo: ["title": menuBarTitle]
        )
        if fanBoost.isEnabled {
            Task {
                let snapshot = await fanBoostController.currentSnapshot(thermalState: report.system.thermalState)
                await MainActor.run { self.fanBoost = snapshot }
            }
        }
        runState.apply(.finish)
    }

    private static func makeMenuBarTitle(from codex: Availability<CodexDiagnosticSnapshot>) -> String {
        guard case .available(let snapshot) = codex else {
            return "~ —"
        }

        let remaining = snapshot.primaryLimit.map { "\($0.remainingPercent)%" } ?? "—"
        let tokens: String
        if let tokensToday = snapshot.tokensToday {
            tokens = tokensToday.formatted(.number.notation(.compactName))
        } else {
            tokens = "—"
        }
        return "~ \(remaining) · \(tokens)"
    }

    func setFanBoostEnabled(_ enabled: Bool) {
        let thermal = report?.system.thermalState ?? .unavailable
        if enabled {
            fanBoost = FanBoostController.Snapshot(
                isEnabled: true,
                mode: .needsPrivilege,
                statusText: "Waiting for access",
                detailText: "Approve admin once — then toggles stay unlocked",
                rpm: fanBoost.rpm
            )
        } else {
            fanBoost = FanBoostController.Snapshot(
                isEnabled: false,
                mode: .off,
                statusText: "Off",
                detailText: "Stopping boost…",
                rpm: fanBoost.rpm
            )
        }
        Task {
            let snapshot = await fanBoostController.setEnabled(enabled, thermalState: thermal)
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
        let isOn = model.isFanBoostEnabled
        return ControlCenterCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "fan")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isOn ? Color.green : Color.secondary)
                    Text("FAN")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isOn ? Color.green : Color.secondary)
                    Spacer(minLength: 4)
                    Toggle("", isOn: Binding(
                        get: { model.isFanBoostEnabled },
                        set: { model.setFanBoostEnabled($0) }
                    ))
                    .toggleStyle(FanBoostToggleStyle())
                    .labelsHidden()
                    .accessibilityLabel("Fan Boost")
                }

                FanWindAnimationView(isRunning: isOn)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.fanBoost.statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isOn ? Color.green : Color.primary)
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
        HStack(spacing: 18) {
            ControlCenterAction(
                title: "Open",
                systemImage: "macwindow",
                tint: .blue
            ) {
                NotificationCenter.default.post(name: .tildeOpenMainWindow, object: nil)
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
