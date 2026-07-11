import AppKit
import SwiftUI
import TildeCore

@main
struct TildeDiagnosticsApp: App {
    @StateObject private var model = DiagnosticViewModel()

    var body: some Scene {
        WindowGroup("Tilde Diagnostics", id: "diagnostics") {
            DiagnosticContentView()
                .environmentObject(model)
                .frame(minWidth: 680, minHeight: 520)
        }
        .defaultSize(width: 760, height: 720)

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(model)
        } label: {
            Label("Tilde", systemImage: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class DiagnosticViewModel: ObservableObject {
    @Published var report: DiagnosticReport?
    @Published var runState = DiagnosticRunState.idle
    @Published private(set) var history: [LiveMetricSample] = []
    private let liveMonitoring = LiveMonitoringService()
    private var historyBuffer = LiveMetricHistory()
    private var subscriptionTask: Task<Void, Never>?

    var menuBarSymbol: String {
        if runState == .running { return "ellipsis.circle" }
        guard let report else { return "waveform.path.ecg" }
        if report.system.thermalState == .critical { return "exclamationmark.triangle.fill" }
        if case .available(let memory) = report.system.memory, memory.pressure == .critical {
            return "exclamationmark.triangle.fill"
        }
        return "waveform.path.ecg"
    }

    func startIfNeeded() {
        guard subscriptionTask == nil else { return }
        runState.apply(.start)
        subscriptionTask = Task { [weak self] in
            guard let self else { return }
            let reports = await liveMonitoring.reports()
            for await report in reports {
                guard !Task.isCancelled else { break }
                self.report = report
                self.historyBuffer.append(LiveMetricSample(snapshot: report.system))
                self.history = self.historyBuffer.samples
                self.runState.apply(.finish)
            }
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
            }
        }
        .onAppear { model.setPresentation(presentationID, isActive: true) }
        .onDisappear { model.setPresentation(presentationID, isActive: false) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tilde")
                    .font(.title2.weight(.semibold))
                Text(freshnessText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .padding(16)
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
        HStack(spacing: 18) {
            SummaryMetric(
                title: "CPU",
                value: cpuPercent(report.system.cpu).map(percent) ?? "--",
                detail: "Live utilization",
                color: cpuPercent(report.system.cpu).map(MetricColor.utilization) ?? .secondary
            )
            Divider().frame(height: 54)
            SummaryMetric(
                title: "Memory",
                value: memoryPercent(report.system.memory).map(percent) ?? "--",
                detail: pressureValue(report.system.memory),
                color: memoryColor(report.system.memory)
            )
            Divider().frame(height: 54)
            SummaryMetric(
                title: "Storage",
                value: storagePercent(report.system.storage).map(percent) ?? "--",
                detail: storageValue(report.system.storage),
                color: storagePercent(report.system.storage).map(MetricColor.utilization) ?? .secondary
            )
            Divider().frame(height: 54)
            SummaryMetric(
                title: "Codex",
                value: codexRemaining(report.codex).map { "\($0)%" } ?? "--",
                detail: "Allowance remaining",
                color: codexRemaining(report.codex).map(MetricColor.remaining) ?? .secondary
            )
        }
        .padding(.vertical, 4)
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
                    color: memory.pressure == .normal ? MetricColor.utilization(usage) : MetricColor.memoryPressure(memory.pressure),
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

    private func networkAndPowerSection(_ snapshot: SystemSnapshot) -> some View {
        MonitorSection(title: "Network & Power", symbol: "network") {
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

    @ViewBuilder
    private func codexSection(_ availability: Availability<CodexDiagnosticSnapshot>) -> some View {
        MonitorSection(title: "Codex", symbol: "terminal") {
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

    private func sensorSection(_ snapshot: AdvancedSensorSnapshot) -> some View {
        MonitorSection(title: "Advanced Sensors", symbol: "sensor") {
            MetricRow(label: "CPU Temperature", value: availabilityText(snapshot.cpuTemperature) { "\($0.formatted()) C" })
            MetricRow(label: "GPU Utilization", value: availabilityText(snapshot.gpuUsage) { percent($0) })
            MetricRow(label: "Fan Speed", value: availabilityText(snapshot.fanSpeeds) { readings in
                readings.map { "\($0.rpm) RPM" }.joined(separator: ", ")
            })
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
        return value.pressure == .normal
            ? MetricColor.utilization(memoryPercent(availability) ?? 0)
            : MetricColor.memoryPressure(value.pressure)
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

private struct MenuBarPanel: View {
    @EnvironmentObject private var model: DiagnosticViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var presentationID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(panelStatusColor)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tilde")
                        .font(.headline)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.runState == .running {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                if let report = model.report {
                    Text("Performance")
                        .font(.headline)
                    performanceBars(report)
                    LiveResourceChart(samples: model.history, compact: true)
                    Divider()
                    networkRows(report.system.network)
                } else {
                    Text("Collecting diagnostics...")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .padding(16)

            Divider()

            HStack(spacing: 8) {
                Button {
                    openWindow(id: "diagnostics")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Open Tilde", systemImage: "macwindow")
                }

                Spacer()

                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Run Diagnostics")
                .disabled(model.runState == .running)

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit Tilde")
            }
            .padding(12)
        }
        .frame(width: 380)
        .onAppear { model.setPresentation(presentationID, isActive: true) }
        .onDisappear { model.setPresentation(presentationID, isActive: false) }
    }

    @ViewBuilder
    private func performanceBars(_ report: DiagnosticReport) -> some View {
        if case .available(let cpu) = report.system.cpu {
            MetricBar(
                label: "CPU",
                value: percent(cpu.usagePercent),
                fraction: cpu.usagePercent / 100,
                color: MetricColor.utilization(cpu.usagePercent)
            )
        } else {
            MetricBar(label: "CPU", value: "Unavailable", fraction: nil, color: .secondary)
        }

        if case .available(let memory) = report.system.memory, memory.totalBytes > 0 {
            let usage = Double(memory.usedBytes) / Double(memory.totalBytes) * 100
            MetricBar(
                label: "Memory",
                value: percent(usage),
                fraction: usage / 100,
                color: memory.pressure == .normal ? MetricColor.utilization(usage) : MetricColor.memoryPressure(memory.pressure),
                detail: memory.pressure.rawValue.capitalized
            )
        } else {
            MetricBar(label: "Memory", value: "Unavailable", fraction: nil, color: .secondary)
        }

        if case .available(let codex) = report.codex, let remaining = codex.primaryLimit?.remainingPercent {
            MetricBar(
                label: "Codex",
                value: "\(remaining)% remaining",
                fraction: Double(remaining) / 100,
                color: MetricColor.remaining(remaining)
            )
        } else {
            MetricBar(label: "Codex", value: "Unavailable", fraction: nil, color: .secondary)
        }
    }

    @ViewBuilder
    private func networkRows(_ availability: Availability<NetworkReading>) -> some View {
        if case .available(let network) = availability {
            HStack(spacing: 20) {
                Label(network.downloadBytesPerSecond.map(rate) ?? "--", systemImage: "arrow.down")
                    .foregroundStyle(.green)
                Label(network.uploadBytesPerSecond.map(rate) ?? "--", systemImage: "arrow.up")
                    .foregroundStyle(.purple)
                Spacer()
                Text(network.interfaceName ?? "Offline")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        } else {
            Text("Network unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private func percent(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...1))))%"
    }

    private func rate(_ bytesPerSecond: Double) -> String {
        "\((bytesPerSecond * 8 / 1_000_000).formatted(.number.precision(.fractionLength(1)))) Mbps"
    }
}

private struct MetricRow: View {
    let label: String
    let value: String
    var isUnavailable = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
            Spacer(minLength: 24)
            Text(value.isEmpty ? "Unavailable" : value)
                .foregroundStyle(isUnavailable || value.isEmpty ? .secondary : .primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }
}
