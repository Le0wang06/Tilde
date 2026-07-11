import SwiftUI
import TildeCore

@main
struct TildeDiagnosticsApp: App {
    var body: some Scene {
        WindowGroup("Tilde Diagnostics") {
            DiagnosticContentView()
                .frame(minWidth: 680, minHeight: 520)
        }
        .defaultSize(width: 760, height: 720)
    }
}

@MainActor
private final class DiagnosticViewModel: ObservableObject {
    @Published var report: DiagnosticReport?
    @Published var isRunning = false
    private let coordinator = MonitoringCoordinator()
    private var refreshTask: Task<Void, Never>?

    func refresh() {
        refreshTask?.cancel()
        isRunning = true
        refreshTask = Task {
            let report = await coordinator.runDiagnostics()
            guard !Task.isCancelled else { return }
            self.report = report
            isRunning = false
        }
    }
}

private struct DiagnosticContentView: View {
    @StateObject private var model = DiagnosticViewModel()

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
        .task { model.refresh() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tilde Phase 0 Diagnostics")
                    .font(.headline)
                Text("Feasibility checks only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRunning {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                model.refresh()
            } label: {
                Label("Run Diagnostics", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRunning)
        }
        .padding(16)
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
