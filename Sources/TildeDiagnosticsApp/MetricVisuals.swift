import Charts
import SwiftUI
import TildeCore

struct MonitorSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline)
            Divider()
            content
        }
    }
}

struct SummaryMetric: View {
    let title: String
    let value: String
    let detail: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title2.monospacedDigit())
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct MetricBar: View {
    let label: String
    let value: String
    let fraction: Double?
    let color: Color
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 20)
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(fraction == nil ? .secondary : .primary)
            }
            if let fraction {
                ProgressView(value: min(1, max(0, fraction)))
                    .progressViewStyle(.linear)
                    .tint(color)
                    .accessibilityLabel(label)
                    .accessibilityValue(value)
            }
        }
        .padding(.vertical, 4)
    }
}

struct LiveResourceChart: View {
    let samples: [LiveMetricSample]
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !compact {
                HStack {
                    Text("Resource Load")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    ChartLegendItem(label: "CPU", color: .blue)
                    ChartLegendItem(label: "Memory", color: .orange)
                }
            }
            Chart(samples) { sample in
                if let cpu = sample.cpuPercent {
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("CPU", cpu),
                        series: .value("Metric", "CPU")
                    )
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                if let memory = sample.memoryPercent {
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Memory", memory),
                        series: .value("Metric", "Memory")
                    )
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis {
                if !compact {
                    AxisMarks(position: .leading, values: [0, 50, 100]) {
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
            }
            .frame(height: compact ? 74 : 150)
            .accessibilityLabel("CPU and memory history")
        }
        .padding(compact ? 0 : 12)
        .background {
            if !compact {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
        }
    }
}

struct LiveNetworkChart: View {
    let samples: [LiveMetricSample]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Network Throughput")
                    .font(.subheadline.weight(.medium))
                Spacer()
                ChartLegendItem(label: "Down", color: .green)
                ChartLegendItem(label: "Up", color: .purple)
            }
            Chart(samples) { sample in
                if let download = sample.downloadMbps {
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Download", download),
                        series: .value("Direction", "Download")
                    )
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                if let upload = sample.uploadMbps {
                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Upload", upload),
                        series: .value("Direction", "Upload")
                    )
                    .foregroundStyle(.purple)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) {
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 150)
            .accessibilityLabel("Network throughput history in megabits per second")
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
    }
}

struct ChartLegendItem: View {
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 12, height: 3)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

enum MetricColor {
    static func utilization(_ percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 75 { return .orange }
        return .green
    }

    static func remaining(_ percent: Int) -> Color {
        if percent <= 10 { return .red }
        if percent <= 25 { return .orange }
        return .green
    }

    static func memoryPressure(_ pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        case .unavailable: .secondary
        }
    }
}
