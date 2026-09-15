import Testing
@testable import StoplightCore

@Test func summaryReportsNothingWhenNoSessionsAreActive() {
    #expect(LightState().summary == "No active Claude sessions")
}

@Test func summaryUsesSingularVerbForOneSessionNeedingAttention() {
    #expect(LightState(failed: 0, attention: 1, running: 0).summary == "1 needs attention")
}

@Test func summaryUsesPluralVerbForSeveralSessionsNeedingAttention() {
    #expect(LightState(failed: 0, attention: 3, running: 0).summary == "3 need attention")
}

@Test func summaryOrdersRunningThenAttentionThenFailed() {
    let state = LightState(failed: 1, attention: 2, running: 3)
    #expect(state.summary == "3 running, 2 need attention, 1 failed")
}

@Test func summaryOmitsEmptyBuckets() {
    #expect(LightState(failed: 0, attention: 0, running: 2).summary == "2 running")
}

@Test func countMapsEachLampToItsOwnBucket() {
    let state = LightState(failed: 1, attention: 2, running: 3)
    #expect(state.count(.red) == 1)
    #expect(state.count(.yellow) == 2)
    #expect(state.count(.green) == 3)
}

@Test func lampSlotsAreFixedLeftToRight() {
    // Slot position is the primary visual encoding — reordering these would
    // silently break readability for anyone who cannot rely on hue.
    #expect(Lamp.red.rawValue == 0)
    #expect(Lamp.yellow.rawValue == 1)
    #expect(Lamp.green.rawValue == 2)
    #expect(Lamp.allCases == [.red, .yellow, .green])
}
