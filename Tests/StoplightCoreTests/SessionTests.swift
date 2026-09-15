import Testing
import Foundation
@testable import StoplightCore

private func json(_ raw: String) -> Data { Data(raw.utf8) }

/// A realistic file, matching what Claude Code 2.1.272 actually writes.
private let liveSession = """
{"pid":84858,"sessionId":"c0dd0de4-67d7-4ae1-a839-979d586ad7f8",
 "cwd":"/Users/justis/dev/stoplight","startedAt":1789497998337,
 "procStart":"Tue Sep 15 18:46:37 2026","version":"2.1.272","peerProtocol":1,
 "kind":"interactive","entrypoint":"cli","pidDomain":"darwin",
 "messagingSocketPath":"/tmp/cc-socks/84858.sock","name":"stoplight-df",
 "nameSource":"derived","status":"busy","updatedAt":1789498243784,
 "statusUpdatedAt":1789498243784}
"""

// MARK: - Decoding

@Test func decodesARealSessionFile() {
    let session = SessionDecoder.session(from: json(liveSession))
    #expect(session?.pid == 84858)
    #expect(session?.cwd == "/Users/justis/dev/stoplight")
    #expect(session?.name == "stoplight-df")
    #expect(session?.version == "2.1.272")
    #expect(session?.status == .busy)
}

@Test func convertsMillisecondTimestamps() {
    let session = SessionDecoder.session(from: json(liveSession))
    #expect(session?.statusUpdatedAt == Date(timeIntervalSince1970: 1789498243.784))
}

@Test func derivesFolderFromWorkingDirectory() {
    #expect(SessionDecoder.session(from: json(liveSession))?.folder == "stoplight")
}

@Test func rejectsAFileWithoutAPid() {
    #expect(SessionDecoder.session(from: json(#"{"sessionId":"abc"}"#)) == nil)
}

@Test func rejectsAFileWithoutASessionId() {
    #expect(SessionDecoder.session(from: json(#"{"pid":123}"#)) == nil)
}

@Test func rejectsMalformedJSON() {
    #expect(SessionDecoder.session(from: json("{not json")) == nil)
}

@Test func survivesAFileMissingEveryOptionalField() {
    // The tolerant-reader contract: a future Claude Code version dropping or
    // renaming fields must degrade, not crash or discard the session.
    let session = SessionDecoder.session(from: json(#"{"pid":42,"sessionId":"x"}"#))
    #expect(session?.pid == 42)
    #expect(session?.status == .unknown(""))
    #expect(session?.version == "unknown")
    #expect(session?.startedAt == nil)
}

@Test func keepsAnUnrecognisedStatusVerbatimRatherThanGuessing() {
    let session = SessionDecoder.session(
        from: json(#"{"pid":42,"sessionId":"x","status":"compacting"}"#))
    #expect(session?.status == .unknown("compacting"))
}

// MARK: - Buckets

private func session(status: String, changedSecondsAgo: TimeInterval, now: Date) -> Session {
    let changed = now.addingTimeInterval(-changedSecondsAgo).timeIntervalSince1970 * 1000
    return SessionDecoder.session(from: json("""
    {"pid":1,"sessionId":"x","status":"\(status)","statusUpdatedAt":\(changed)}
    """))!
}

@Test func busySessionsAreRunning() {
    let now = Date()
    #expect(session(status: "busy", changedSecondsAgo: 0, now: now).bucket(now: now) == .running)
}

@Test func aSessionThatJustFinishedWantsAttention() {
    let now = Date()
    #expect(session(status: "idle", changedSecondsAgo: 10, now: now).bucket(now: now) == .attention)
}

@Test func attentionDecaysToIdleAfterTheWindow() {
    // A task that finished an hour ago is not attention, it is just idle.
    let now = Date()
    #expect(session(status: "idle", changedSecondsAgo: 3600, now: now).bucket(now: now) == .idle)
}

@Test func attentionBoundaryIsExclusive() {
    let now = Date()
    let window = Session.defaultRecentWindow
    #expect(session(status: "idle", changedSecondsAgo: window - 1, now: now).bucket(now: now) == .attention)
    #expect(session(status: "idle", changedSecondsAgo: window + 1, now: now).bucket(now: now) == .idle)
}

@Test func anUnknownStatusNeverLightsALamp() {
    let now = Date()
    #expect(session(status: "compacting", changedSecondsAgo: 1, now: now).bucket(now: now) == .idle)
}

@Test func anIdleSessionWithNoTimestampIsIdleNotAttention() {
    let session = SessionDecoder.session(from: json(#"{"pid":1,"sessionId":"x","status":"idle"}"#))!
    #expect(session.bucket() == .idle)
}

// MARK: - Aggregation

@Test func lightStateCountsEachBucketSeparately() {
    let now = Date()
    let state = LightState(sessions: [
        session(status: "busy", changedSecondsAgo: 0, now: now),
        session(status: "busy", changedSecondsAgo: 0, now: now),
        session(status: "idle", changedSecondsAgo: 5, now: now),
        session(status: "idle", changedSecondsAgo: 9999, now: now),
    ], now: now)

    #expect(state.running == 2)
    #expect(state.attention == 1)
    #expect(state.failed == 0)
    #expect(state.summary == "2 running, 1 needs attention")
}

@Test func noSessionsMeansEveryLampIsDark() {
    let state = LightState(sessions: [])
    #expect(state == LightState())
    #expect(state.summary == "No active Claude sessions")
}
