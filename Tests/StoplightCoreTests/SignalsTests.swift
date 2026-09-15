import Testing
import Foundation
@testable import StoplightCore

private func transcript(_ lines: [String]) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "stoplight-signals-\(UUID().uuidString).jsonl")
    try Data(lines.joined(separator: "\n").utf8).write(to: url)
    return url
}

// MARK: - Rate limits

@Test func aLiveRateLimitIsDetected() throws {
    let resets = Date().addingTimeInterval(3600).timeIntervalSince1970
    let url = try transcript([
        #"{"type":"assistant","quotaLimits":{"status":"rejected","rateLimitType":"seven_day","resetsAt":\#(resets)}}"#
    ])
    defer { try? FileManager.default.removeItem(at: url) }

    let limit = try #require(TranscriptReader.snapshot(at: url).rateLimit)
    #expect(limit.status == "rejected")
    #expect(limit.type == "seven_day")
    #expect(limit.isActive())
}

@Test func anExpiredRateLimitIsNotActive() {
    let limit = RateLimit(status: "rejected", type: "seven_day",
                          resetsAt: Date().addingTimeInterval(-60))
    #expect(limit.isActive() == false)
}

@Test func anAllowedQuotaIsNotARateLimit() {
    let limit = RateLimit(status: "allowed", type: nil,
                          resetsAt: Date().addingTimeInterval(3600))
    #expect(limit.isActive() == false)
}

@Test func aRateLimitedSessionShowsAsFailed() {
    // It is stalled no matter what its status field says.
    let session = SessionDecoder.session(from: Data(#"{"pid":1,"sessionId":"x","status":"busy"}"#.utf8))!
    var snapshot = TranscriptSnapshot()
    snapshot.rateLimit = RateLimit(status: "rejected", type: "seven_day",
                                   resetsAt: Date().addingTimeInterval(600))
    #expect(session.bucket(snapshot: snapshot) == .failed)
}

@Test func theResetTimeIsSpelledOut() {
    let limit = RateLimit(status: "rejected", type: "seven_day",
                          resetsAt: Date().addingTimeInterval(3600))
    let text = Notifier.resetDescription(limit)
    #expect(text.contains("seven day"))
    #expect(text.contains("resets at"))
}

// MARK: - Session context

@Test func branchAndPermissionModeAreRead() throws {
    let url = try transcript([
        #"{"type":"user","gitBranch":"feature/panel","permissionMode":"plan"}"#
    ])
    defer { try? FileManager.default.removeItem(at: url) }

    let snapshot = TranscriptReader.snapshot(at: url)
    #expect(snapshot.gitBranch == "feature/panel")
    #expect(snapshot.permissionMode == "plan")
}

@Test func aDetachedHeadIsNotShownAsABranch() {
    // "HEAD" names no branch and would only be noise in a row.
    let data = Data(#"{"type":"user","gitBranch":"HEAD"}"#.utf8)
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "stoplight-head-\(UUID().uuidString).jsonl")
    try? data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(TranscriptReader.snapshot(at: url).gitBranch == nil)
}

// MARK: - Attribution tallies

@Test func skillsAndServersAreTallied() throws {
    let url = try transcript([
        #"{"attributionSkill":"dataviz"}"#,
        #"{"attributionSkill":"dataviz"}"#,
        #"{"attributionSkill":"adhd"}"#,
        #"{"attributionMcpServer":"aws-mcp"}"#,
        #"{"type":"compactMetadata-ish","compactMetadata":{"trigger":"auto"}}"#,
        #"{"type":"user","cwd":"/Users/x/dev/proj"}"#,
        #"{"type":"cost-state","sessionId":"s","totalCostUSD":1.0,"modelUsage":{}}"#,
    ])
    defer { try? FileManager.default.removeItem(at: url) }

    let cost = try #require(CostStateReader.costState(at: url))
    #expect(cost.skills["dataviz"] == 2)
    #expect(cost.skills["adhd"] == 1)
    #expect(cost.mcpServers["aws-mcp"] == 1)
    #expect(cost.compactions == 1)
}

@Test func tallyingScansTheWholeFileNotJustTheTail() throws {
    // Attributions cluster early in a session; a tail-only scan would miss them.
    let url = try transcript(
        [#"{"attributionSkill":"early"}"#]
        + Array(repeating: #"{"type":"assistant"}"#, count: 900)
        + [#"{"type":"cost-state","sessionId":"s","totalCostUSD":1.0,"modelUsage":{}}"#])
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(CostStateReader.costState(at: url)?.skills["early"] == 1)
}

@Test func anAbsentAttributionTalliesToNothing() throws {
    let url = try transcript([#"{"type":"cost-state","sessionId":"s","totalCostUSD":1,"modelUsage":{}}"#])
    defer { try? FileManager.default.removeItem(at: url) }
    let cost = try #require(CostStateReader.costState(at: url))
    #expect(cost.skills.isEmpty)
    #expect(cost.compactions == 0)
}

// MARK: - Aggregation

@Test func skillsAggregateAcrossSessionsAndRankByUse() {
    let now = Date()
    var a = CostState(); a.skills = ["dataviz": 2, "adhd": 9]; a.compactions = 1
    var b = CostState(); b.skills = ["dataviz": 5]; b.compactions = 2
    let summary = ScoreboardBuilder.summarize(
        [ScoredSession(cost: a, lastActive: now), ScoredSession(cost: b, lastActive: now)],
        crashes: [], range: .all, totalTranscripts: 2, now: now)

    #expect(summary.skills.map(\.name) == ["adhd", "dataviz"])
    #expect(summary.skills.first?.count == 9)
    #expect(summary.compactions == 3)
}
