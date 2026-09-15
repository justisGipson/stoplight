import Testing
import Foundation
@testable import StoplightCore

private func transcript(_ lines: [String]) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "stoplight-transcript-\(UUID().uuidString).jsonl")
    try Data(lines.joined(separator: "\n").utf8).write(to: url)
    return url
}

private func assistant(_ content: String, usage: String = "") -> String {
    let usagePart = usage.isEmpty ? "" : ",\"usage\":\(usage)"
    return #"{"type":"assistant","message":{"content":[\#(content)]\#(usagePart)}}"#
}

private let toolUse = #"{"type":"tool_use","id":"toolu_1","name":"Bash"}"#
private let toolResult = #"{"type":"tool_result","tool_use_id":"toolu_1"}"#

// MARK: - Line splitting

@Test func lastLinesReturnsNewestFirst() {
    let data = Data("a\nb\nc".utf8)
    #expect(TranscriptReader.lastLines(of: data, limit: 10).map { String(decoding: $0, as: UTF8.self) }
            == ["c", "b", "a"])
}

@Test func lastLinesToleratesATrailingNewline() {
    let data = Data("a\nb\n".utf8)
    #expect(TranscriptReader.lastLines(of: data, limit: 10).map { String(decoding: $0, as: UTF8.self) }
            == ["b", "a"])
}

@Test func lastLinesStopsAtTheLimit() {
    let data = Data((1...100).map(String.init).joined(separator: "\n").utf8)
    let lines = TranscriptReader.lastLines(of: data, limit: 3)
    #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["100", "99", "98"])
}

@Test func lastLinesOfEmptyDataIsEmpty() {
    #expect(TranscriptReader.lastLines(of: Data(), limit: 10).isEmpty)
}

// MARK: - Current tool

@Test func anUnansweredToolUseIsTheRunningTool() throws {
    let url = try transcript([assistant(toolUse)])
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(TranscriptReader.snapshot(at: url).currentTool == "Bash")
}

@Test func aToolUseWithAResultIsNoLongerRunning() throws {
    // The result comes after the call, so a reverse scan meets it first.
    let url = try transcript([assistant(toolUse), assistant(toolResult)])
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(TranscriptReader.snapshot(at: url).currentTool == nil)
}

@Test func onlyTheNewestToolCallCounts() throws {
    let url = try transcript([
        assistant(#"{"type":"tool_use","id":"old","name":"Read"}"#),
        assistant(#"{"type":"tool_result","tool_use_id":"old"}"#),
        assistant(toolUse),
    ])
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(TranscriptReader.snapshot(at: url).currentTool == "Bash")
}

// MARK: - Tokens

@Test func contextTokensComeFromTheMostRecentUsage() throws {
    let url = try transcript([
        assistant(#"{"type":"text","text":"old"}"#, usage: #"{"input_tokens":10}"#),
        assistant(#"{"type":"text","text":"new"}"#,
                  usage: #"{"input_tokens":5,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200}"#),
    ])
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(TranscriptReader.snapshot(at: url).contextTokens == 1205)
}

// MARK: - Errors

@Test func aRecentApiErrorIsReported() throws {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let url = try transcript([
        #"{"type":"assistant","isApiErrorMessage":true,"apiErrorStatus":429,"timestamp":"\#(stamp)"}"#
    ])
    defer { try? FileManager.default.removeItem(at: url) }

    let snapshot = TranscriptReader.snapshot(at: url)
    #expect(snapshot.lastErrorStatus == 429)
    #expect(snapshot.hasRecentError())
}

@Test func anOldApiErrorIsNotRecent() {
    let snapshot = TranscriptSnapshot(
        lastErrorStatus: 429,
        lastErrorAt: Date().addingTimeInterval(-TranscriptSnapshot.errorWindow - 1))
    #expect(snapshot.hasRecentError() == false)
}

@Test func aMissingTranscriptYieldsAnEmptySnapshot() {
    let snapshot = TranscriptReader.snapshot(at: URL(fileURLWithPath: "/nowhere.jsonl"))
    #expect(snapshot.isEmpty)
}

@Test func garbageLinesAreSkippedRatherThanFatal() throws {
    let url = try transcript(["not json at all", assistant(toolUse)])
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(TranscriptReader.snapshot(at: url).currentTool == "Bash")
}
