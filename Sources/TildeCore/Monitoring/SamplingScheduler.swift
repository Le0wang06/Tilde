import Foundation

public enum LiveMetric: CaseIterable, Hashable, Sendable {
    case cpu
    case memory
    case network
    case battery
    case storage
    case thermal
    case advancedSensors
    case codex
}

public struct SamplingInterval: Equatable, Sendable {
    public let foreground: TimeInterval
    public let background: TimeInterval

    public init(foreground: TimeInterval, background: TimeInterval) {
        self.foreground = foreground
        self.background = background
    }

    public func value(isForeground: Bool) -> TimeInterval {
        isForeground ? foreground : background
    }
}

public struct AdaptiveSamplingPolicy: Sendable {
    private let intervals: [LiveMetric: SamplingInterval]

    public static let standard = AdaptiveSamplingPolicy(intervals: [
        .cpu: SamplingInterval(foreground: 1, background: 5),
        .memory: SamplingInterval(foreground: 2, background: 10),
        .network: SamplingInterval(foreground: 1, background: 5),
        .battery: SamplingInterval(foreground: 15, background: 60),
        .storage: SamplingInterval(foreground: 60, background: 300),
        .thermal: SamplingInterval(foreground: 2, background: 10),
        .advancedSensors: SamplingInterval(foreground: 2, background: 10),
        .codex: SamplingInterval(foreground: 60, background: 120),
    ])

    public init(intervals: [LiveMetric: SamplingInterval]) {
        self.intervals = intervals
    }

    public func interval(for metric: LiveMetric, isForeground: Bool) -> TimeInterval {
        intervals[metric]?.value(isForeground: isForeground) ?? 60
    }

    public func dueMetrics(
        lastSampled: [LiveMetric: Date],
        now: Date,
        isForeground: Bool
    ) -> Set<LiveMetric> {
        Set(LiveMetric.allCases.filter { metric in
            guard let date = lastSampled[metric] else { return true }
            return now.timeIntervalSince(date) >= interval(for: metric, isForeground: isForeground)
        })
    }

    public func schedulerTick(isForeground: Bool) -> TimeInterval {
        isForeground ? 1 : 5
    }
}
