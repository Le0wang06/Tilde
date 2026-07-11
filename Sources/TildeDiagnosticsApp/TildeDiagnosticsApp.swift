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
    private let liveMonitoring = LiveMonitoringService()
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
                LazyVStack(spacing: 16) {
                    if let report = model.report {
                        systemSection(report.system)
                        sensorSection(report.system.advancedSensors)
                        codexSection(report.codex)
                    } else {
                        ContentUnavailableView(
                            "No Diagnostic Results",
                            systemImage: "stethoscope",
                            description: Text("Run diagnostics to test system providers and Codex connectivity.")
                        )
                        .frame(minHeight: 420)
                    }
                }
                .padding(20)
            }
        }
        .onAppear { model.setPresentation(presentationID, isActive: true) }
        .onDisappear { model.setPresentation(presentationID, isActive: false) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tilde Phase 0 Diagnostics")
                    .font(.headline)
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
                Label("Run Diagnostics", systemImage: "arrow.clockwise")
            }
            .disabled(model.runState == .running)
        }
        .padding(16)
    }

    private var freshnessText: String {
        guard let report = model.report else { return "Starting live monitoring" }
        return "Live · Updated \(report.system.timestamp.formatted(date: .omitted, time: .standard))"
    }

    private func systemSection(_ snapshot: SystemSnapshot) -> some View {
        DiagnosticSection(title: "System", symbol: "desktopcomputer") {
            availabilityRow("CPU", snapshot.cpu) { "\($0.usagePercent.formatted(.number.precision(.fractionLength(1))))%" }
            availabilityRow("Memory", snapshot.memory) {
                "\(bytes($0.usedBytes)) / \(bytes($0.totalBytes))"
            }
            availabilityRow("Memory Pressure", snapshot.memory) { $0.pressure.rawValue.capitalized }
            availabilityRow("Swap", snapshot.memory) { bytes($0.swapUsedBytes) }
            availabilityRow("Storage", snapshot.storage) {
                "\(bytes($0.usedBytes)) / \(bytes($0.totalBytes))"
            }
            availabilityRow("Download", snapshot.network) {
                $0.downloadBytesPerSecond.map(rate) ?? "Collecting baseline"
            }
            availabilityRow("Upload", snapshot.network) {
                $0.uploadBytesPerSecond.map(rate) ?? "Collecting baseline"
            }
            availabilityRow("Local IP", snapshot.network) { $0.localIPAddress ?? "Unavailable" }
            availabilityRow("Network Interface", snapshot.network) { $0.interfaceName ?? "Unavailable" }
            availabilityRow("Battery", snapshot.battery) {
                $0.percent.map { "\($0.formatted(.number.precision(.fractionLength(0))))%" } ?? "Unavailable"
            }
            availabilityRow("Power Source", snapshot.battery) { $0.isOnACPower ? "Adapter" : "Battery" }
            MetricRow(label: "Thermal State", value: snapshot.thermalState.rawValue.capitalized)
        }
    }

    private func sensorSection(_ snapshot: AdvancedSensorSnapshot) -> some View {
        DiagnosticSection(title: "Advanced Sensors", symbol: "sensor") {
            availabilityRow("CPU Temperature", snapshot.cpuTemperature) { "\($0.formatted()) C" }
            availabilityRow("GPU Utilization", snapshot.gpuUsage) { "\($0.formatted())%" }
            availabilityRow("Fan Speed", snapshot.fanSpeeds) { readings in
                readings.map { "\($0.rpm) RPM" }.joined(separator: ", ")
            }
        }
    }

    @ViewBuilder
    private func codexSection(_ availability: Availability<CodexDiagnosticSnapshot>) -> some View {
        DiagnosticSection(title: "Codex", symbol: "terminal") {
            switch availability {
            case .available(let codex):
                MetricRow(label: "Connection", value: "Working")
                MetricRow(label: "Version", value: codex.version)
                MetricRow(label: "Authentication", value: codex.isAuthenticated ? "Working" : "Required")
                MetricRow(label: "Account", value: [codex.accountType, codex.planType].compactMap { $0 }.joined(separator: " / "))
                MetricRow(label: "Codex Remaining", value: codex.primaryLimit.map { "\($0.remainingPercent)%" } ?? "Unavailable")
                MetricRow(label: "Secondary Remaining", value: codex.secondaryLimit.map { "\($0.remainingPercent)%" } ?? "Unavailable")
                MetricRow(label: "Tokens Today", value: codex.tokensToday.map(formatCount) ?? "Unavailable")
                MetricRow(label: "Visible Threads", value: codex.threadCount.map(String.init) ?? "Unavailable")
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

    @ViewBuilder
    private func availabilityRow<Value: Sendable>(
        _ label: String,
        _ availability: Availability<Value>,
        formatter: (Value) -> String
    ) -> some View {
        switch availability {
        case .available(let value):
            MetricRow(label: label, value: formatter(value))
        case .unavailable(let reason):
            MetricRow(label: label, value: "Unavailable - \(reason)", isUnavailable: true)
        case .failed(let message):
            MetricRow(label: label, value: "Failed - \(message)", isUnavailable: true)
        }
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
                Image(systemName: model.menuBarSymbol)
                    .font(.title2)
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

            VStack(spacing: 0) {
                if let report = model.report {
                    panelRows(report)
                } else {
                    Text("Collecting diagnostics...")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .padding(.horizontal, 16)

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
    private func panelRows(_ report: DiagnosticReport) -> some View {
        PanelMetricRow(label: "CPU", value: cpuValue(report.system.cpu))
        PanelMetricRow(label: "Memory", value: memoryValue(report.system.memory))
        PanelMetricRow(label: "Memory Pressure", value: pressureValue(report.system.memory))
        PanelMetricRow(label: "Thermal State", value: report.system.thermalState.rawValue.capitalized)
        PanelMetricRow(label: "Codex Remaining", value: codexRemaining(report.codex))
        PanelMetricRow(label: "Codex Threads", value: codexThreads(report.codex))
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

    private func cpuValue(_ availability: Availability<CPUReading>) -> String {
        guard case .available(let reading) = availability else { return "Unavailable" }
        return "\(reading.usagePercent.formatted(.number.precision(.fractionLength(1))))%"
    }

    private func memoryValue(_ availability: Availability<MemoryReading>) -> String {
        guard case .available(let reading) = availability else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: Int64(reading.usedBytes), countStyle: .memory)
    }

    private func pressureValue(_ availability: Availability<MemoryReading>) -> String {
        guard case .available(let reading) = availability else { return "Unavailable" }
        return reading.pressure.rawValue.capitalized
    }

    private func codexRemaining(_ availability: Availability<CodexDiagnosticSnapshot>) -> String {
        guard case .available(let codex) = availability, let limit = codex.primaryLimit else { return "Unavailable" }
        return "\(limit.remainingPercent)%"
    }

    private func codexThreads(_ availability: Availability<CodexDiagnosticSnapshot>) -> String {
        guard case .available(let codex) = availability, let count = codex.threadCount else { return "Unavailable" }
        return String(count)
    }
}

private struct PanelMetricRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
    }
}

private struct DiagnosticSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(spacing: 0) {
                content
            }
        } label: {
            Label(title, systemImage: symbol)
                .font(.headline)
        }
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
