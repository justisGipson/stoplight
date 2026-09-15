import Testing
import Foundation
@testable import StoplightCore

private func decode(_ raw: String) -> Session {
    SessionDecoder.session(from: Data(raw.utf8))!
}

// MARK: - The real four-value status enum

@Test func shellCountsAsWorking() {
    // Claude Code validates ["busy","shell","idle","waiting"]. `shell` is running
    // a command — still working, so it belongs on green.
    let session = decode(#"{"pid":1,"sessionId":"x","status":"shell"}"#)
    #expect(session.status == .shell)
    #expect(session.status.isWorking)
    #expect(session.bucket() == .running)
}

@Test func waitingMeansBlockedOnYou() {
    let session = decode(#"{"pid":1,"sessionId":"x","status":"waiting"}"#)
    #expect(session.bucket() == .attention)
    #expect(session.status.isWorking == false)
}

@Test func waitingCarriesClaudeCodesOwnReason() {
    // Claude Code writes waitingFor alongside a waiting status: either
    // "permission prompt" or "input needed".
    let session = decode(
        #"{"pid":1,"sessionId":"x","status":"waiting","waitingFor":"permission prompt"}"#)
    #expect(session.status == .waiting("permission prompt"))
}

@Test func waitingWithoutAReasonStillBlocks() {
    #expect(decode(#"{"pid":1,"sessionId":"x","status":"waiting"}"#).status == .waiting(nil))
}

@Test func blockedSessionsDoNotDecayLikeFinishedOnes() {
    // A finished session stops asking after 5 minutes. One blocked on a permission
    // prompt is still blocked an hour later.
    let now = Date()
    let old = now.addingTimeInterval(-86_400).timeIntervalSince1970 * 1000
    let session = decode(
        #"{"pid":1,"sessionId":"x","status":"waiting","statusUpdatedAt":\#(old)}"#)
    #expect(session.bucket(now: now) == .attention)
}

// MARK: - Errors

private func snapshot(secondsAgo: TimeInterval, status: Int = 429) -> TranscriptSnapshot {
    TranscriptSnapshot(lastErrorStatus: status,
                       lastErrorAt: Date().addingTimeInterval(-secondsAgo))
}

@Test func aStalledSessionWithAFreshErrorIsAFailure() {
    let session = decode(#"{"pid":1,"sessionId":"x","status":"idle"}"#)
    #expect(session.bucket(snapshot: snapshot(secondsAgo: 5)) == .failed)
}

@Test func aSessionStillWorkingAfterAnErrorIsNotAFailure() {
    // It retried and carried on. A 529 that resolved itself must not cry wolf.
    let session = decode(#"{"pid":1,"sessionId":"x","status":"busy"}"#)
    #expect(session.bucket(snapshot: snapshot(secondsAgo: 5)) == .running)
}

@Test func anOldErrorDoesNotLightRed() {
    let session = decode(#"{"pid":1,"sessionId":"x","status":"idle"}"#)
    #expect(session.bucket(snapshot: snapshot(secondsAgo: 10_000)) == .idle)
}

@Test func errorsFeedTheAggregateState() {
    let session = decode(#"{"pid":1,"sessionId":"abc","status":"idle"}"#)
    let state = LightState(sessions: [session],
                           snapshots: ["abc": snapshot(secondsAgo: 5)])
    #expect(state.failed == 1)
    #expect(state.summary == "1 failed")
}
