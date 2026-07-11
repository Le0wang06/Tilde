import Testing
@testable import TildeCore

@Test func successfulRunTransitionsFromIdleToCompleted() {
    var state = DiagnosticRunState.idle
    state.apply(.start)
    #expect(state == .running)
    state.apply(.finish)
    #expect(state == .completed)
}

@Test func cancellationOnlyChangesRunningState() {
    var state = DiagnosticRunState.idle
    state.apply(.cancel)
    #expect(state == .idle)
    state.apply(.start)
    state.apply(.cancel)
    #expect(state == .cancelled)
}

@Test func failureOnlyChangesRunningState() {
    var state = DiagnosticRunState.completed
    state.apply(.fail)
    #expect(state == .completed)
    state.apply(.start)
    state.apply(.fail)
    #expect(state == .failed)
}
