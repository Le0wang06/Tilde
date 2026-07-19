import Foundation

public struct ClaudeUsageProbe: Sendable {
    private let environment: [String: String]
    private let localUsageProbe: ClaudeLocalUsageProbe

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        localUsageProbe = ClaudeLocalUsageProbe()
    }

    public func fetchSnapshot(now: Date = Date(), calendar: Calendar = .current) async throws -> ClaudeUsageSnapshot {
        let claudeHome = environment["CLAUDE_CONFIG_DIR"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        let projects = claudeHome.appendingPathComponent("projects", isDirectory: true)
        guard FileManager.default.fileExists(atPath: projects.path) else {
            throw MetricError.unavailable("Claude Code transcripts were not found")
        }

        let messages = localUsageProbe.todayUsage(root: projects, now: now, calendar: calendar)
        guard let estimate = ClaudeCostEstimator.estimate(messages: messages) else {
            let models = Array(Set(messages.map(\.model))).filter { !$0.isEmpty }.sorted()
            return ClaudeUsageSnapshot(
                dailySpend: nil,
                sessionCount: Set(messages.map(\.sessionID)).count,
                pricedMessageCount: 0,
                unpricedModels: models,
                notes: ["No priced Claude assistant usage was found for today."]
            )
        }

        let dayStart = calendar.startOfDay(for: now)
        var notes = [
            "Claude cost is an API-price equivalent from local usage metadata and Anthropic rate card \(ClaudeCostEstimator.rateCardVersion).",
            "Claude Pro and Max include usage; this estimate is not a charge or an authoritative bill.",
        ]
        if !estimate.unpricedModels.isEmpty {
            notes.append("Unpriced Claude models were excluded: \(estimate.unpricedModels.joined(separator: ", ")).")
        }
        return ClaudeUsageSnapshot(
            dailySpend: DailySpendReading(
                provider: .claude,
                cents: estimate.cents,
                basis: .estimatedFromTokenBreakdown,
                observedFrom: dayStart
            ),
            sessionCount: estimate.sessionCount,
            pricedMessageCount: estimate.pricedMessageCount,
            unpricedModels: estimate.unpricedModels,
            notes: notes
        )
    }
}

final class ClaudeLocalUsageProbe: @unchecked Sendable {
    private struct FileState {
        var parser = ClaudeTranscriptUsageParser()
        var offset: UInt64 = 0
        var pending = Data()
    }

    private let lock = NSLock()
    private var cachedDayStart: Date?
    private var fileStates: [String: FileState] = [:]

    func todayUsage(
        root: URL,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ClaudeMessageTokenUsage] {
        lock.lock()
        defer { lock.unlock() }

        let start = calendar.startOfDay(for: now)
        if cachedDayStart != start {
            cachedDayStart = start
            fileStates.removeAll(keepingCapacity: true)
        }
        guard let end = calendar.date(byAdding: .day, value: 1, to: start),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }

        var seenPaths = Set<String>()
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]
            ),
                  values.isRegularFile == true,
                  (values.contentModificationDate ?? .distantPast) >= start else { continue }

            let path = fileURL.path
            seenPaths.insert(path)
            var state = fileStates[path] ?? FileState()
            if UInt64(values.fileSize ?? 0) < state.offset {
                state = FileState()
            }
            readNewLines(at: fileURL, state: &state, interval: start..<end)
            fileStates[path] = state
        }
        fileStates = fileStates.filter { seenPaths.contains($0.key) }

        var combined: [String: ClaudeMessageTokenUsage] = [:]
        for state in fileStates.values {
            for message in state.parser.messages.values {
                combined[message.identity] = combined[message.identity]
                    .map { $0.mergingBestRecord(with: message) } ?? message
            }
        }
        return combined.values.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.identity < $1.identity
        }
    }

    private func readNewLines(
        at url: URL,
        state: inout FileState,
        interval: Range<Date>
    ) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: state.offset)
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            state.pending.append(chunk)
            while let newline = state.pending.firstIndex(of: 0x0A) {
                state.parser.consume(lineData: state.pending[..<newline], interval: interval)
                state.pending.removeSubrange(...newline)
            }
        }
        state.offset = handle.offsetInFile
    }
}
