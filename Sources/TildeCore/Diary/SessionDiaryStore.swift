import Foundation

public enum SessionDiaryEventKind: String, Codable, Sendable {
    case appStarted
    case focusChanged
    case buildStarted
    case buildFinished
    case slowdown
    case agentNeedsInput
    case agentCompleted
    case note
}

public struct SessionDiaryEvent: Codable, Sendable, Equatable {
    public var id: UUID
    public var at: Date
    public var kind: SessionDiaryEventKind
    public var summary: String
    public var detail: String?

    public init(
        id: UUID = UUID(),
        at: Date = Date(),
        kind: SessionDiaryEventKind,
        summary: String,
        detail: String? = nil
    ) {
        self.id = id
        self.at = at
        self.kind = kind
        self.summary = summary
        self.detail = detail
    }
}

public struct SessionDiaryTodaySummary: Sendable, Equatable {
    public var eventCount: Int
    public var builds: Int
    public var slowdowns: Int
    public var focusChanges: Int
    public var lastEventSummary: String?

    public init(
        eventCount: Int,
        builds: Int,
        slowdowns: Int,
        focusChanges: Int,
        lastEventSummary: String? = nil
    ) {
        self.eventCount = eventCount
        self.builds = builds
        self.slowdowns = slowdowns
        self.focusChanges = focusChanges
        self.lastEventSummary = lastEventSummary
    }

    public static let empty = SessionDiaryTodaySummary(
        eventCount: 0,
        builds: 0,
        slowdowns: 0,
        focusChanges: 0,
        lastEventSummary: nil
    )

    public var headline: String {
        if eventCount == 0 { return "No events yet today" }
        return "\(eventCount) events · \(builds) builds"
    }

    public var detailText: String {
        var parts: [String] = []
        if slowdowns > 0 { parts.append("\(slowdowns) slowdown\(slowdowns == 1 ? "" : "s")") }
        if focusChanges > 0 { parts.append("\(focusChanges) focus") }
        if let lastEventSummary {
            parts.append(lastEventSummary)
        }
        return parts.isEmpty ? "Local JSONL under Application Support" : parts.joined(separator: " · ")
    }
}

/// Append-only local diary (JSONL) for today’s coding session signals.
public actor SessionDiaryStore {
    private let fileURL: URL
    private let calendar: Calendar
    private var cachedDay: DateComponents?
    private var cachedEvents: [SessionDiaryEvent] = []

    public init(fileURL: URL? = nil, calendar: Calendar = .current) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let dir = base.appendingPathComponent("Tilde", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("session-diary.jsonl")
        }
        self.calendar = calendar
    }

    public func record(_ event: SessionDiaryEvent) async {
        await loadTodayIfNeeded()
        cachedEvents.append(event)
        appendLine(event)
    }

    public func todaySummary() async -> SessionDiaryTodaySummary {
        await loadTodayIfNeeded()
        let builds = cachedEvents.filter { $0.kind == .buildFinished }.count
        let slowdowns = cachedEvents.filter { $0.kind == .slowdown }.count
        let focusChanges = cachedEvents.filter { $0.kind == .focusChanged }.count
        return SessionDiaryTodaySummary(
            eventCount: cachedEvents.count,
            builds: builds,
            slowdowns: slowdowns,
            focusChanges: focusChanges,
            lastEventSummary: cachedEvents.last?.summary
        )
    }

    private func loadTodayIfNeeded() async {
        let today = calendar.dateComponents([.year, .month, .day], from: Date())
        if cachedDay == today { return }
        cachedDay = today
        cachedEvents = readTodayEvents()
    }

    private func readTodayEvents() -> [SessionDiaryEvent] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var events: [SessionDiaryEvent] = []
        for line in text.split(separator: "\n") where !line.isEmpty {
            guard let lineData = String(line).data(using: .utf8),
                  let event = try? decoder.decode(SessionDiaryEvent.self, from: lineData),
                  calendar.isDateInToday(event.at) else { continue }
            events.append(event)
        }
        return events
    }

    private func appendLine(_ event: SessionDiaryEvent) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(event),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? line.data(using: .utf8)?.write(to: fileURL, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
