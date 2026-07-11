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
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

struct ModernSurface<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            }
    }
}

struct SummaryMetric: View {
    let title: String
    let value: String
    let detail: String
    let color: Color
    var fraction: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 25, weight: .semibold, design: .default).monospacedDigit())
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let fraction {
                ColorBar(fraction: fraction, color: color)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
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
                ColorBar(fraction: fraction, color: color)
                    .accessibilityLabel(label)
                    .accessibilityValue(value)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ColorBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(color.gradient)
                    .frame(width: geometry.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 6)
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
            .chartYAxis(.hidden)
            .frame(height: compact ? 74 : 150)
            .accessibilityLabel("CPU and memory history")
        }
        .padding(compact ? 0 : 16)
        .background(compact ? AnyShapeStyle(.clear) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if !compact {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
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
            .chartYAxis(.hidden)
            .frame(height: 150)
            .accessibilityLabel("Network throughput history in megabits per second")
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
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
