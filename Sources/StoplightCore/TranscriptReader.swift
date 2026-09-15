import Foundation

/// What the tail of a session's transcript can tell us.
public struct TranscriptSnapshot: Equatable, Sendable {
    /// The tool currently executing: a `tool_use` with no `tool_result` after it.
    public var currentTool: String?
    /// Tokens in the most recent request — the session's live context size.
    public var contextTokens: Int?
    public var lastErrorStatus: Int?
    public var lastErrorAt: Date?

    public var isEmpty: Bool {
        currentTool == nil && contextTokens == nil && lastErrorStatus == nil
    }

    /// An API error only matters while it is fresh. A 429 from three hours ago in
    /// a session that carried on working is history, not a problem.
    public func hasRecentError(now: Date = Date(),
                               window: TimeInterval = TranscriptSnapshot.errorWindow) -> Bool {
        guard lastErrorStatus != nil, let at = lastErrorAt else { return false }
        return now.timeIntervalSince(at) < window
    }

    public static let errorWindow: TimeInterval = 300
}

/// Reads `~/.claude/projects/<slug>/<sessionId>.jsonl`.
///
/// Scans backwards from the end and stops early. Everything here lives near the
/// tail — the running tool, the latest usage, the most recent error — so a bounded
/// reverse scan answers all of it without parsing a transcript that may run to
/// tens of thousands of lines. Lifetime totals and cost need a full pass and
/// belong to the scoreboard, not to a hover panel.
public enum TranscriptReader {
    /// Enough to cover a tool call and its result many times over.
    public static let maxLines = 400

    /// Located by searching, not by rebuilding Claude Code's directory-slug rule.
    public static func url(forSessionId id: String, projectsRoot: URL) -> URL? {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil) else { return nil }
        for directory in directories {
            let candidate = directory.appending(path: "\(id).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    nonisolated public static var defaultProjectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects", directoryHint: .isDirectory)
    }

    public static func snapshot(at url: URL, maxLines: Int = TranscriptReader.maxLines)
    -> TranscriptSnapshot {
        var snapshot = TranscriptSnapshot()
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return snapshot }

        // Going backwards, a tool_result is seen before the tool_use it answers.
        // So the first tool_use whose id we have *not* already seen is still running.
        var answeredToolUses: Set<String> = []
        var resolvedTool = false

        for line in lastLines(of: data, limit: maxLines) {
            guard let object = try? JSONSerialization.jsonObject(with: line),
                  let json = object as? [String: Any] else { continue }

            if snapshot.lastErrorStatus == nil, json["isApiErrorMessage"] as? Bool == true {
                snapshot.lastErrorStatus = json["apiErrorStatus"] as? Int ?? 0
                snapshot.lastErrorAt = date(json["timestamp"] as? String)
            }

            guard let message = json["message"] as? [String: Any] else { continue }

            if snapshot.contextTokens == nil, let usage = message["usage"] as? [String: Any] {
                let input = usage["input_tokens"] as? Int ?? 0
                let cached = usage["cache_read_input_tokens"] as? Int ?? 0
                let created = usage["cache_creation_input_tokens"] as? Int ?? 0
                let total = input + cached + created
                if total > 0 { snapshot.contextTokens = total }
            }

            if !resolvedTool, let blocks = message["content"] as? [[String: Any]] {
                for block in blocks.reversed() {
                    switch block["type"] as? String {
                    case "tool_result":
                        if let id = block["tool_use_id"] as? String { answeredToolUses.insert(id) }
                    case "tool_use":
                        guard let id = block["id"] as? String else { continue }
                        if !answeredToolUses.contains(id) {
                            snapshot.currentTool = block["name"] as? String
                        }
                        // The newest tool_use settles it either way.
                        resolvedTool = true
                    default:
                        continue
                    }
                    if resolvedTool { break }
                }
            }

            if resolvedTool, snapshot.contextTokens != nil, snapshot.lastErrorStatus != nil { break }
        }
        return snapshot
    }

    /// Newest first, without splitting the whole file.
    static func lastLines(of data: Data, limit: Int) -> [Data] {
        var lines: [Data] = []
        var end = data.endIndex
        let newline = UInt8(ascii: "\n")

        while end > data.startIndex, lines.count < limit {
            var start = end - 1
            // Skip the trailing newline of the previous line.
            if data[start] == newline, end == data.endIndex { end = start; continue }
            while start > data.startIndex, data[start - 1] != newline { start -= 1 }
            if start < end { lines.append(data[start..<end]) }
            end = start > data.startIndex ? start - 1 : data.startIndex
        }
        return lines
    }

    static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = withFraction.date(from: raw) { return parsed }
        return ISO8601DateFormatter().date(from: raw)
    }
}
