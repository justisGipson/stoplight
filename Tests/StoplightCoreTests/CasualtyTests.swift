import Testing
import Foundation
@testable import StoplightCore

private func session(pid: pid_t, status: String) -> Session {
    SessionDecoder.session(from: Data("""
    {"pid":\(pid),"sessionId":"s\(pid)","status":"\(status)","cwd":"/Users/x/dev/proj\(pid)"}
    """.utf8))!
}

@Test func aSessionThatVanishesWhileBusyIsACasualty() {
    let now = Date()
    let found = SessionWatcher.casualties(previous: [session(pid: 1, status: "busy")],
                                          current: [], now: now)
    #expect(found.count == 1)
    #expect(found.first?.pid == 1)
    #expect(found.first?.folder == "proj1")
}

@Test func aSessionThatVanishesWhileIdleIsACleanExit() {
    // Quitting normally settles to idle first, so this is not a failure.
    let found = SessionWatcher.casualties(previous: [session(pid: 1, status: "idle")],
                                          current: [], now: Date())
    #expect(found.isEmpty)
}

@Test func aBusySessionThatIsStillRunningIsNotACasualty() {
    let busy = session(pid: 1, status: "busy")
    #expect(SessionWatcher.casualties(previous: [busy], current: [busy], now: Date()).isEmpty)
}

@Test func onlyTheVanishedSessionsAreRecorded() {
    let found = SessionWatcher.casualties(
        previous: [session(pid: 1, status: "busy"), session(pid: 2, status: "busy")],
        current: [session(pid: 2, status: "busy")],
        now: Date())
    #expect(found.map(\.pid) == [1])
}

@Test func anUnknownStatusIsNotTreatedAsAFailure() {
    // Never invent red from a status we do not understand.
    let found = SessionWatcher.casualties(previous: [session(pid: 1, status: "hibernating")],
                                          current: [], now: Date())
    #expect(found.isEmpty)
}

@Test func casualtiesExpireAfterTheirWindow() {
    let died = Date()
    let casualty = Casualty(pid: 1, sessionId: "s", folder: "proj", diedAt: died)
    #expect(casualty.isActive(now: died.addingTimeInterval(60)))
    #expect(casualty.isActive(now: died.addingTimeInterval(Casualty.defaultWindow + 1)) == false)
}

@Test func casualtiesOutliveTheAttentionWindow() {
    // A crash you missed because you stepped away should still be on screen when
    // you get back, long after a merely-finished session has gone quiet.
    #expect(Casualty.defaultWindow > Session.defaultRecentWindow)
}

@Test func activeCasualtiesLightTheRedLamp() {
    let now = Date()
    let state = LightState(sessions: [], casualties: [
        Casualty(pid: 1, sessionId: "a", folder: "one", diedAt: now),
        Casualty(pid: 2, sessionId: "b", folder: "two", diedAt: now),
    ], now: now)

    #expect(state.failed == 2)
    #expect(state.summary == "2 failed")
}

@Test func expiredCasualtiesDoNotLightTheRedLamp() {
    let now = Date()
    let old = now.addingTimeInterval(-Casualty.defaultWindow - 1)
    let state = LightState(sessions: [],
                           casualties: [Casualty(pid: 1, sessionId: "a", folder: "one", diedAt: old)],
                           now: now)
    #expect(state.failed == 0)
}

@Test func failuresCombineWithLiveSessionsInOneState() {
    let now = Date()
    let state = LightState(sessions: [session(pid: 9, status: "busy")],
                           casualties: [Casualty(pid: 1, sessionId: "a", folder: "one", diedAt: now)],
                           now: now)
    #expect(state.running == 1)
    #expect(state.failed == 1)
    #expect(state.summary == "1 running, 1 failed")
}
