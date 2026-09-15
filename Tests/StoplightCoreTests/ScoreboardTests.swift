import Testing
import Foundation
@testable import StoplightCore

private func write(_ lines: [String], to directory: URL, named name: String) throws -> URL {
    let url = directory.appending(path: name)
    try Data(lines.joined(separator: "\n").utf8).write(to: url)
    return url
}

private func tempDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "stoplight-score-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func costLine(cost: Double, input: Int = 100, output: Int = 50, model: String = "opus") -> String {
    """
    {"type":"cost-state","sessionId":"s1","totalCostUSD":\(cost),"totalLinesAdded":7,\
    "totalLinesRemoved":2,"totalToolDuration":5000,"startTime":1787763532776,\
    "modelUsage":{"\(model)":{"inputTokens":\(input),"outputTokens":\(output),\
    "cacheReadInputTokens":1000,"cacheCreationInputTokens":0,"costUSD":\(cost)}}}
    """
}

private let cwdLine = #"{"type":"user","cwd":"/Users/x/dev/lesson-generation-agent"}"#

/// Scan then aggregate over all time — what the old single-shot build did.
private func buildAll(_ root: URL, _ store: inout ScoreboardStore) -> ScoreboardSummary {
    let scanned = ScoreboardBuilder.scan(projectsRoot: root, store: &store)
    return ScoreboardBuilder.summarize(scanned, crashes: store.crashes, range: .all,
                                       totalTranscripts: ScoreboardBuilder.transcripts(in: root).count)
}

// MARK: - Reading cost-state

@Test func readsACostStateRollup() throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = try write([cwdLine, costLine(cost: 12.5)], to: directory, named: "a.jsonl")

    let cost = CostStateReader.costState(at: url)
    #expect(cost?.totalCostUSD == 12.5)
    #expect(cost?.linesAdded == 7)
    #expect(cost?.totalTokens == 1150)
}

@Test func usesTheLastRollupBecauseTheyAreCumulative() throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = try write([costLine(cost: 1.0), costLine(cost: 9.0)], to: directory, named: "a.jsonl")
    #expect(CostStateReader.costState(at: url)?.totalCostUSD == 9.0)
}

@Test func findsTheRollupEvenWhenItIsNotTheLastLine() throws {
    // Observed in the wild 131 lines from the end of a 13,000-line transcript.
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let trailing = Array(repeating: #"{"type":"assistant"}"#, count: 300)
    let url = try write([cwdLine, costLine(cost: 3.0)] + trailing, to: directory, named: "a.jsonl")
    #expect(CostStateReader.costState(at: url)?.totalCostUSD == 3.0)
}

@Test func projectNameComesFromCwdNotTheMangledDirectoryName() throws {
    // "-Users-x-dev-lesson-generation-agent" cannot be split back apart, because
    // the separator also appears inside the project's own name.
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = try write([cwdLine, costLine(cost: 1.0)], to: directory, named: "a.jsonl")
    #expect(CostStateReader.costState(at: url)?.folder == "lesson-generation-agent")
}

@Test func aTranscriptWithNoRollupYieldsNothing() throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = try write([#"{"type":"assistant"}"#], to: directory, named: "a.jsonl")
    #expect(CostStateReader.costState(at: url) == nil)
}

@Test func aMissingTranscriptYieldsNothing() {
    #expect(CostStateReader.costState(at: URL(fileURLWithPath: "/nowhere.jsonl")) == nil)
}

// MARK: - Aggregation

@Test func buildsTotalsAcrossProjects() throws {
    let root = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let one = root.appending(path: "-Users-x-dev-alpha", directoryHint: .isDirectory)
    let two = root.appending(path: "-Users-x-dev-beta", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: two, withIntermediateDirectories: true)
    _ = try write([#"{"cwd":"/Users/x/dev/alpha"}"#, costLine(cost: 2.0)], to: one, named: "a.jsonl")
    _ = try write([#"{"cwd":"/Users/x/dev/beta"}"#, costLine(cost: 8.0)], to: two, named: "b.jsonl")

    var store = ScoreboardStore()
    let summary = buildAll(root, &store)

    #expect(summary.totalCostUSD == 10.0)
    #expect(summary.sessions == 2)
    #expect(summary.transcriptsSeen == 2)
    // Ranked by cost, so the expensive project leads.
    #expect(summary.projects.map(\.folder) == ["beta", "alpha"])
}

@Test func transcriptsWithoutCostAreCountedButNotBilled() throws {
    let root = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appending(path: "-Users-x-dev-alpha", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    _ = try write([#"{"type":"assistant"}"#], to: project, named: "short.jsonl")

    var store = ScoreboardStore()
    let summary = buildAll(root, &store)
    #expect(summary.transcriptsSeen == 1)
    #expect(summary.transcriptsWithCost == 0)
    #expect(summary.totalCostUSD == 0)
}

@Test func anUnchangedTranscriptIsNotRescanned() throws {
    // 107 MB of transcripts on this machine; rescanning them on every window open
    // is the difference between instant and not.
    let root = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appending(path: "-Users-x-dev-alpha", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let url = try write([cwdLine, costLine(cost: 4.0)], to: project, named: "a.jsonl")

    var store = ScoreboardStore()
    _ = buildAll(root, &store)
    // Keyed by the path directory enumeration produced, which resolves /var to
    // /private/var — not necessarily the string we built the file from.
    #expect(store.entries.count == 1)
    let key = try #require(store.entries.keys.first)
    #expect(store.entries[key]?.cost?.totalCostUSD == 4.0)

    // Poison the cached value while leaving the recorded size and mtime alone.
    // The file on disk still says 4.0, so getting 42.0 back can only mean the
    // builder trusted the cache and never reopened it.
    store.entries[key]?.cost?.totalCostUSD = 42.0
    #expect(buildAll(root, &store).totalCostUSD == 42.0)

    // Touching the file invalidates the entry and the real value returns.
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                          ofItemAtPath: url.path)
    #expect(buildAll(root, &store).totalCostUSD == 4.0)
}

@Test func storeRoundTripsThroughDisk() throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "scoreboard.json")

    var store = ScoreboardStore()
    store.crashes = ["alpha|123"]
    store.entries["/x.jsonl"] = .init(size: 10, modified: Date(timeIntervalSince1970: 5), cost: nil)
    store.save(to: url)

    #expect(ScoreboardStore.load(from: url) == store)
}

@Test func loadingAnAbsentStoreYieldsAnEmptyOne() {
    #expect(ScoreboardStore.load(from: URL(fileURLWithPath: "/nowhere.json")) == ScoreboardStore())
}

// MARK: - Claude Code's own stats cache

@Test func parsesTheStatsCache() throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "stats.json")
    try Data(#"{"totalSessions":52,"totalMessages":9902,"lastComputedDate":"2026-07-12","hourCounts":{"9":11}}"#.utf8)
        .write(to: url)

    let stats = ClaudeStats.load(from: url)
    #expect(stats?.totalSessions == 52)
    #expect(stats?.hourCounts[9] == 11)
    // Claude Code recomputes this only occasionally — it lagged two months here.
    #expect(stats?.isStale == true)
}

@Test func aFreshlyComputedCacheIsNotStale() throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "stats.json")
    let today = ClaudeStats.dayFormatter.string(from: Date())
    try Data(#"{"totalSessions":1,"lastComputedDate":"\#(today)"}"#.utf8).write(to: url)
    #expect(ClaudeStats.load(from: url)?.isStale == false)
}

// MARK: - Time ranges

private func scored(cost: Double, daysAgo: Double, folder: String = "alpha",
                    now: Date = Date()) -> ScoredSession {
    var state = CostState()
    state.totalCostUSD = cost
    state.folder = folder
    state.modelUsage = ["opus": ModelUsage(inputTokens: 100, costUSD: cost)]
    return ScoredSession(cost: state, lastActive: now.addingTimeInterval(-daysAgo * 86_400))
}

@Test func allTimeIncludesEverything() {
    let now = Date()
    let summary = ScoreboardBuilder.summarize(
        [scored(cost: 1, daysAgo: 1, now: now), scored(cost: 2, daysAgo: 400, now: now)],
        crashes: [], range: .all, totalTranscripts: 2, now: now)
    #expect(summary.totalCostUSD == 3)
    #expect(summary.sessions == 2)
}

@Test func sevenDaysExcludesOlderSessions() {
    let now = Date()
    let summary = ScoreboardBuilder.summarize(
        [scored(cost: 1, daysAgo: 2, now: now), scored(cost: 99, daysAgo: 30, now: now)],
        crashes: [], range: .week, totalTranscripts: 2, now: now)
    #expect(summary.totalCostUSD == 1)
    #expect(summary.sessions == 1)
}

@Test func allTimeIsWiderThanSevenDays() {
    let now = Date()
    let sessions = [scored(cost: 1, daysAgo: 2, now: now),
                    scored(cost: 10, daysAgo: 20, now: now)]
    let week = ScoreboardBuilder.summarize(sessions, crashes: [], range: .week,
                                           totalTranscripts: 2, now: now)
    let all = ScoreboardBuilder.summarize(sessions, crashes: [], range: .all,
                                          totalTranscripts: 2, now: now)
    #expect(week.totalCostUSD == 1)
    #expect(all.totalCostUSD == 11)
}

@Test func onlyTwoRangesAreOffered() {
    // A 30-day option would duplicate "all time" under Claude Code's default
    // 30-day transcript retention.
    #expect(TimeRange.allCases.map(\.label) == ["7 days", "All time"])
}

@Test func earliestActivityIsReportedRegardlessOfRange() {
    // The retention floor has to show even when the range is narrower than it.
    let now = Date()
    let summary = ScoreboardBuilder.summarize(
        [scored(cost: 1, daysAgo: 1, now: now), scored(cost: 1, daysAgo: 40, now: now)],
        crashes: [], range: .week, totalTranscripts: 2, now: now)
    #expect(summary.earliestActivity != nil)
    #expect(now.timeIntervalSince(summary.earliestActivity!) > 39 * 86_400)
}

@Test func theRangeBoundaryIsInclusive() {
    let now = Date()
    // Exactly seven days old still counts as the last seven days.
    #expect(TimeRange.week.contains(now.addingTimeInterval(-7 * 86_400), now: now))
    #expect(TimeRange.week.contains(now.addingTimeInterval(-7 * 86_400 - 60), now: now) == false)
}

@Test func rangesAlsoFilterProjectsAndModels() {
    let now = Date()
    let summary = ScoreboardBuilder.summarize(
        [scored(cost: 5, daysAgo: 1, folder: "recent", now: now),
         scored(cost: 5, daysAgo: 90, folder: "ancient", now: now)],
        crashes: [], range: .week, totalTranscripts: 2, now: now)
    #expect(summary.projects.map { $0.folder } == ["recent"])
    #expect(summary.models.first?.costUSD == 5)
}

@Test func crashesAreFilteredByRangeToo() {
    let now = Date()
    let recent = "alpha|\(Int(now.addingTimeInterval(-3600).timeIntervalSince1970))"
    let old = "beta|\(Int(now.addingTimeInterval(-90 * 86_400).timeIntervalSince1970))"

    let week = ScoreboardBuilder.summarize([], crashes: [recent, old], range: .week,
                                           totalTranscripts: 0, now: now)
    let all = ScoreboardBuilder.summarize([], crashes: [recent, old], range: .all,
                                          totalTranscripts: 0, now: now)
    #expect(week.crashes == 1)
    #expect(all.crashes == 2)
}

@Test func anUnparseableCrashRecordNeverInflatesARecentWindow() {
    let now = Date()
    let summary = ScoreboardBuilder.summarize([], crashes: ["garbage"], range: .week,
                                              totalTranscripts: 0, now: now)
    #expect(summary.crashes == 0)
}
