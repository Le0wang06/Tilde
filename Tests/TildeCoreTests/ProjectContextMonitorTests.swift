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
