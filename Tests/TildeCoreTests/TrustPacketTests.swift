import Testing
@testable import TildeCore

@Test func numstatParserCountsTextChangesAndIgnoresBinaryMarkers() {
    let parsed = TrustPacketProvider.parseNumstat("12\t3\tSources/App.swift\n-\t-\tasset.png\n4\t0\tREADME.md\n")
    #expect(parsed.additions == 16)
    #expect(parsed.deletions == 3)
}
@Test func sensitivePathDetectionCoversHighRiskProjectFiles() {
    #expect(TrustPacketProvider.isSensitivePath("Package.swift"))
    #expect(TrustPacketProvider.isSensitivePath(".github/workflows/release.yml"))
    #expect(TrustPacketProvider.isSensitivePath("App/Auth/Login.swift"))
    #expect(!TrustPacketProvider.isSensitivePath("Sources/MetricVisuals.swift"))
}
