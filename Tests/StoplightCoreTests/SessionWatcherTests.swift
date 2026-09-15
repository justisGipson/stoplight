import Testing
import Foundation
@testable import StoplightCore

/// Writes a throwaway sessions directory so the scan runs against real files.
private func fixture(_ files: [String: String]) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "stoplight-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (name, contents) in files {
        try Data(contents.utf8).write(to: directory.appending(path: name))
    }
    return directory
}

private func alive(_: pid_t) -> Bool { true }
private func dead(_: pid_t) -> Bool { false }

@Test func scanReadsEverySessionInTheDirectory() throws {
    let directory = try fixture([
        "1.json": #"{"pid":1,"sessionId":"a","status":"busy","cwd":"/tmp/one"}"#,
        "2.json": #"{"pid":2,"sessionId":"b","status":"idle","cwd":"/tmp/two"}"#,
    ])
    defer { try? FileManager.default.removeItem(at: directory) }

    let (sessions, diagnostics) = SessionWatcher.scan(directory: directory, isAlive: alive)
    #expect(sessions.count == 2)
    #expect(diagnostics.filesSeen == 2)
    #expect(diagnostics.live == 2)
}

@Test func scanDropsSessionsWhoseProcessIsGone() throws {
    // Session files outlive their process; a week-old orphan must not light a lamp.
    let directory = try fixture(["1.json": #"{"pid":1,"sessionId":"a","status":"busy"}"#])
    defer { try? FileManager.default.removeItem(at: directory) }

    let (sessions, diagnostics) = SessionWatcher.scan(directory: directory, isAlive: dead)
    #expect(sessions.isEmpty)
    #expect(diagnostics.stale == 1)
    #expect(diagnostics.live == 0)
}

@Test func oneUnreadableFileDoesNotDiscardTheOthers() throws {
    let directory = try fixture([
        "1.json": "{{{ garbage",
        "2.json": #"{"pid":2,"sessionId":"b","status":"busy"}"#,
    ])
    defer { try? FileManager.default.removeItem(at: directory) }

    let (sessions, diagnostics) = SessionWatcher.scan(directory: directory, isAlive: alive)
    #expect(sessions.count == 1)
    #expect(diagnostics.unreadable == 1)
}

@Test func scanIgnoresNonJSONFiles() throws {
    // The directory also holds per-session .key files.
    let directory = try fixture([
        "1.json": #"{"pid":1,"sessionId":"a","status":"busy"}"#,
        "1.abc123.key": "not a session",
    ])
    defer { try? FileManager.default.removeItem(at: directory) }

    let (sessions, diagnostics) = SessionWatcher.scan(directory: directory, isAlive: alive)
    #expect(sessions.count == 1)
    #expect(diagnostics.filesSeen == 1)
    #expect(diagnostics.unreadable == 0)
}

@Test func scanReportsUnknownStatusesForDiagnosis() throws {
    let directory = try fixture([
        "1.json": #"{"pid":1,"sessionId":"a","status":"hibernating"}"#,
    ])
    defer { try? FileManager.default.removeItem(at: directory) }

    let (_, diagnostics) = SessionWatcher.scan(directory: directory, isAlive: alive)
    #expect(diagnostics.unknownStatuses == ["hibernating"])
}

@Test func scanOfAMissingDirectoryIsEmptyRatherThanAnError() {
    let (sessions, diagnostics) = SessionWatcher.scan(
        directory: URL(fileURLWithPath: "/nowhere/at/all"), isAlive: alive)
    #expect(sessions.isEmpty)
    #expect(diagnostics.filesSeen == 0)
}

@Test func busySessionsSortAboveIdleOnes() throws {
    let directory = try fixture([
        "1.json": #"{"pid":1,"sessionId":"a","status":"idle","statusUpdatedAt":9000}"#,
        "2.json": #"{"pid":2,"sessionId":"b","status":"busy","statusUpdatedAt":1000}"#,
    ])
    defer { try? FileManager.default.removeItem(at: directory) }

    let (sessions, _) = SessionWatcher.scan(directory: directory, isAlive: alive)
    #expect(sessions.map(\.pid) == [2, 1])
}

@Test func theCurrentProcessCountsAsAlive() {
    #expect(SessionWatcher.processExists(getpid()))
}

@Test func anImpossiblePidCountsAsDead() {
    #expect(SessionWatcher.processExists(pid_t(Int32.max)) == false)
}
