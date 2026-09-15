import Foundation

public struct ModelUsage: Equatable, Sendable, Codable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var thinkingTokens = 0
    public var cacheReadInputTokens = 0
    public var cacheCreationInputTokens = 0
    public var costUSD = 0.0

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadInputTokens + cacheCreationInputTokens
    }
}

/// Claude Code's own cumulative rollup for a session, written to the transcript as
/// a `cost-state` line: cost, per-model token counts, durations and edit volume.
public struct CostState: Equatable, Sendable, Codable {
    public var sessionId = ""
    public var folder = ""
    public var totalCostUSD = 0.0
    public var totalDurationMs = 0
    public var totalToolDurationMs = 0
    public var linesAdded = 0
    public var linesRemoved = 0
    public var startTime: Date?
    /// Timestamp of the last entry in the transcript.
    public var lastActivity: Date?
    public var modelUsage: [String: ModelUsage] = [:]
    /// How often each skill and MCP server was credited for work in this session.
    public var skills: [String: Int] = [:]
    public var mcpServers: [String: Int] = [:]
    /// Context compactions. A session compacting repeatedly is churning its cache.
    public var compactions = 0

    public var totalTokens: Int { modelUsage.values.reduce(0) { $0 + $1.totalTokens } }
}

/// Finds the last `cost-state` line in a transcript.
///
/// These lines are rare — five in a thirteen-thousand-line transcript — but each
/// one is cumulative, so only the last matters, and they sit near the end. A
/// backwards byte search for the literal finds it without parsing any JSON along
/// the way, which is what keeps a 36 MB transcript affordable.
public enum CostStateReader {
    /// Generous: the tail holds the answer, but a session that ended with a long
    /// burst of output can push the last rollup a good way back.
    public static let scanLimit = 8_000_000

    public static func costState(at url: URL, scanLimit: Int = CostStateReader.scanLimit) -> CostState? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty
        else { return nil }

        let floor = max(data.startIndex, data.endIndex - scanLimit)
        guard let line = lastLine(containing: Array("\"cost-state\"".utf8), in: data, notBefore: floor),
              let object = try? JSONSerialization.jsonObject(with: line),
              let json = object as? [String: Any],
              json["type"] as? String == "cost-state"
        else { return nil }

        var state = CostState()
        state.sessionId = json["sessionId"] as? String ?? ""
        state.totalCostUSD = json["totalCostUSD"] as? Double ?? 0
        state.totalDurationMs = json["totalDuration"] as? Int ?? 0
        state.totalToolDurationMs = json["totalToolDuration"] as? Int ?? 0
        state.linesAdded = json["totalLinesAdded"] as? Int ?? 0
        state.linesRemoved = json["totalLinesRemoved"] as? Int ?? 0
        if let start = json["startTime"] as? Double, start > 0 {
            state.startTime = Date(timeIntervalSince1970: start / 1000)
        }

        for (model, raw) in (json["modelUsage"] as? [String: [String: Any]] ?? [:]) {
            var usage = ModelUsage()
            usage.inputTokens = raw["inputTokens"] as? Int ?? 0
            usage.outputTokens = raw["outputTokens"] as? Int ?? 0
            usage.thinkingTokens = raw["thinkingTokens"] as? Int ?? 0
            usage.cacheReadInputTokens = raw["cacheReadInputTokens"] as? Int ?? 0
            usage.cacheCreationInputTokens = raw["cacheCreationInputTokens"] as? Int ?? 0
            usage.costUSD = raw["costUSD"] as? Double ?? 0
            state.modelUsage[model] = usage
        }

        state.folder = folder(in: data, notBefore: floor) ?? ""
        state.lastActivity = lastActivity(in: data, notBefore: floor)
        state.skills = values(forKey: "attributionSkill", in: data)
        state.mcpServers = values(forKey: "attributionMcpServer", in: data)
        state.compactions = occurrences(of: Array("\"compactMetadata\"".utf8), in: data)
        return state
    }

    /// The project name, taken from a `cwd` in the transcript rather than by
    /// un-mangling the directory name — `-Users-justis-dev-lesson-generation-agent`
    /// cannot be split back apart, because the separator also occurs inside names.
    static func folder(in data: Data, notBefore floor: Data.Index) -> String? {
        guard let line = lastLine(containing: Array("\"cwd\":\"".utf8), in: data, notBefore: floor),
              let object = try? JSONSerialization.jsonObject(with: line),
              let cwd = (object as? [String: Any])?["cwd"] as? String, !cwd.isEmpty
        else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// When the transcript was last written to, from its own contents.
    static func lastActivity(in data: Data, notBefore floor: Data.Index) -> Date? {
        guard let line = lastLine(containing: Array("\"timestamp\":\"".utf8),
                                  in: data, notBefore: floor),
              let object = try? JSONSerialization.jsonObject(with: line),
              let stamp = (object as? [String: Any])?["timestamp"] as? String
        else { return nil }
        return TranscriptReader.date(stamp)
    }

    /// Tallies the values of a string key across the whole file.
    ///
    /// Scans bytes and slices out each value rather than decoding JSON: these keys
    /// appear on a small fraction of lines, and parsing every line of a 36 MB
    /// transcript to find them would cost orders of magnitude more.
    static func values(forKey key: String, in data: Data) -> [String: Int] {
        let needle = Array("\"\(key)\":\"".utf8)
        let quote = UInt8(ascii: "\"")
        var counts: [String: Int] = [:]
        var index = data.startIndex

        while index + needle.count < data.endIndex {
            guard let hit = firstRange(of: needle, in: data, from: index) else { break }
            var end = hit.upperBound
            while end < data.endIndex, data[end] != quote { end += 1 }
            if end > hit.upperBound {
                let value = String(decoding: data[hit.upperBound..<end], as: UTF8.self)
                counts[value, default: 0] += 1
            }
            index = end
        }
        return counts
    }

    static func occurrences(of needle: [UInt8], in data: Data) -> Int {
        var count = 0
        var index = data.startIndex
        while let hit = firstRange(of: needle, in: data, from: index) {
            count += 1
            index = hit.upperBound
        }
        return count
    }

    static func firstRange(of needle: [UInt8], in data: Data,
                           from start: Data.Index) -> Range<Data.Index>? {
        guard !needle.isEmpty, start >= data.startIndex else { return nil }
        var probe = start
        let limit = data.endIndex - needle.count
        while probe <= limit {
            var matched = true
            for offset in 0..<needle.count where data[probe + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return probe..<(probe + needle.count) }
            probe += 1
        }
        return nil
    }

    /// Last line containing `needle`, searching backwards.
    static func lastLine(containing needle: [UInt8], in data: Data, notBefore floor: Data.Index) -> Data? {
        guard !needle.isEmpty, data.count >= needle.count else { return nil }
        let newline = UInt8(ascii: "\n")

        var probe = data.endIndex - needle.count
        while probe >= floor {
            var matched = true
            for offset in 0..<needle.count where data[probe + offset] != needle[offset] {
                matched = false
                break
            }
            if matched {
                var start = probe
                while start > data.startIndex, data[start - 1] != newline { start -= 1 }
                var end = probe
                while end < data.endIndex, data[end] != newline { end += 1 }
                return start < end ? data[start..<end] : nil
            }
            probe -= 1
        }
        return nil
    }
}
