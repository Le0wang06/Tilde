import Foundation
import Testing
@testable import TildeCore

@Test func ciParserAcceptsOnlyTheCurrentCommit() {
    let data = Data("""
    [{"status":"completed","conclusion":"success","displayTitle":"Tests","headSha":"abc123"}]
    """.utf8)

    let matching = ProjectContextMonitor.parseCIStatus(data, matchingHead: "abc123")
    let stale = ProjectContextMonitor.parseCIStatus(data, matchingHead: "different")

    #expect(matching.status == .success)
    #expect(matching.summary == "Tests")
    #expect(stale.status == .unknown)
    #expect(stale.summary == "No CI for current commit")
}

@Test func ciParserReportsMissingCurrentCommitRunWithoutBorrowingAnotherRun() {
    let result = ProjectContextMonitor.parseCIStatus(Data("[]".utf8), matchingHead: "abc123")

    #expect(result.status == .unknown)
    #expect(result.summary == "No CI for current commit")
}

@Test func pullRequestParserAcceptsOnlyTheCurrentCommit() {
    let data = Data("""
    [
      {"headRefOid":"old","url":"https://example.test/old"},
      {"headRefOid":"current","url":"https://example.test/current"}
    ]
    """.utf8)

    #expect(ProjectContextMonitor.parsePullRequestURL(data, matchingHead: "current") == "https://example.test/current")
    #expect(ProjectContextMonitor.parsePullRequestURL(data, matchingHead: "missing") == nil)
}

@Test func exactWorktreeLookupNeverFallsBackToAnotherActiveRepository() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tilde-not-a-repo-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let snapshot = await ProjectContextMonitor().snapshot(rootPath: directory.path)

    #expect(snapshot == .empty)
}
