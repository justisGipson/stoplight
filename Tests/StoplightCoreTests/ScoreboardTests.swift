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
    let summary = ScoreboardBuilder.build(projectsRoot: root, store: &store)

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
    let summary = ScoreboardBuilder.build(projectsRoot: root, store: &store)
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
    _ = ScoreboardBuilder.build(projectsRoot: root, store: &store)
    // Keyed by the path directory enumeration produced, which resolves /var to
    // /private/var — not necessarily the string we built the file from.
    #expect(store.entries.count == 1)
    let key = try #require(store.entries.keys.first)
    #expect(store.entries[key]?.cost?.totalCostUSD == 4.0)

    // Poison the cached value while leaving the recorded size and mtime alone.
    // The file on disk still says 4.0, so getting 42.0 back can only mean the
    // builder trusted the cache and never reopened it.
    store.entries[key]?.cost?.totalCostUSD = 42.0
    #expect(ScoreboardBuilder.build(projectsRoot: root, store: &store).totalCostUSD == 42.0)

    // Touching the file invalidates the entry and the real value returns.
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                          ofItemAtPath: url.path)
    #expect(ScoreboardBuilder.build(projectsRoot: root, store: &store).totalCostUSD == 4.0)
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
