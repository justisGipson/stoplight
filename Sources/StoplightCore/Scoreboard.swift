import Foundation

public struct ProjectTotals: Equatable, Identifiable, Sendable {
    public var folder: String
    public var sessions = 0
    public var costUSD = 0.0
    public var tokens = 0
    public var linesAdded = 0
    public var linesRemoved = 0
    public var id: String { folder }
}

public struct ModelTotals: Equatable, Identifiable, Sendable {
    public var model: String
    public var costUSD = 0.0
    public var tokens = 0
    public var id: String { model }
}

public struct ScoreboardSummary: Equatable, Sendable {
    public var totalCostUSD = 0.0
    public var totalTokens = 0
    public var sessions = 0
    public var linesAdded = 0
    public var linesRemoved = 0
    public var toolTimeMs = 0
    public var projects: [ProjectTotals] = []
    public var models: [ModelTotals] = []
    public var transcriptsSeen = 0
    public var transcriptsWithCost = 0
    /// Failures this app watched happen. Nothing on disk records these.
    public var crashes = 0

    public var isEmpty: Bool { transcriptsWithCost == 0 && crashes == 0 }
}

/// Persisted between launches.
///
/// Deliberately a JSON file rather than SQLite. The design called for SQLite, but
/// the shape here is one row per transcript with no querying beyond summing —
/// a few hundred entries, read whole and written whole. SQLite would add a C API,
/// a schema and migrations to buy indexing nobody needs.
public struct ScoreboardStore: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var size: Int
        public var modified: Date
        public var cost: CostState?
    }

    public var entries: [String: Entry] = [:]
    /// Crash records survive restarts; the in-memory casualty list does not.
    public var crashes: [String] = []

    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
            .appending(path: "Stoplight", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appending(path: "scoreboard.json")
    }

    public static func load(from url: URL = ScoreboardStore.defaultURL) -> ScoreboardStore {
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(ScoreboardStore.self, from: data)
        else { return ScoreboardStore() }
        return store
    }

    public func save(to url: URL = ScoreboardStore.defaultURL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

public enum ScoreboardBuilder {
    /// Walks every transcript, reusing cached rollups for files that have not grown.
    public static func build(projectsRoot: URL, store: inout ScoreboardStore) -> ScoreboardSummary {
        var summary = ScoreboardSummary()
        var projects: [String: ProjectTotals] = [:]
        var models: [String: ModelTotals] = [:]

        for url in transcripts(in: projectsRoot) {
            summary.transcriptsSeen += 1

            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = attributes?[.size] as? Int ?? 0
            let modified = attributes?[.modificationDate] as? Date ?? .distantPast

            let cached = store.entries[url.path]
            let cost: CostState?
            if let cached, cached.size == size, cached.modified == modified {
                cost = cached.cost
            } else {
                cost = CostStateReader.costState(at: url)
                store.entries[url.path] = .init(size: size, modified: modified, cost: cost)
            }

            // A transcript with no cost-state line is a session too short to bill.
            guard let cost else { continue }
            summary.transcriptsWithCost += 1
            summary.totalCostUSD += cost.totalCostUSD
            summary.totalTokens += cost.totalTokens
            summary.linesAdded += cost.linesAdded
            summary.linesRemoved += cost.linesRemoved
            summary.toolTimeMs += cost.totalToolDurationMs

            let name = cost.folder.isEmpty ? "unknown" : cost.folder
            var project = projects[name] ?? ProjectTotals(folder: name)
            project.sessions += 1
            project.costUSD += cost.totalCostUSD
            project.tokens += cost.totalTokens
            project.linesAdded += cost.linesAdded
            project.linesRemoved += cost.linesRemoved
            projects[name] = project

            for (model, usage) in cost.modelUsage {
                var totals = models[model] ?? ModelTotals(model: model)
                totals.costUSD += usage.costUSD
                totals.tokens += usage.totalTokens
                models[model] = totals
            }
        }

        summary.sessions = summary.transcriptsWithCost
        summary.crashes = store.crashes.count
        summary.projects = projects.values.sorted { $0.costUSD > $1.costUSD }
        summary.models = models.values.sorted { $0.costUSD > $1.costUSD }
        return summary
    }

    static func transcripts(in root: URL) -> [URL] {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        return directories.flatMap { directory in
            (try? FileManager.default.contentsOfDirectory(at: directory,
                                                          includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "jsonl" } ?? []
        }
    }
}

/// Reads `~/.claude/stats-cache.json`, which Claude Code maintains itself.
public struct ClaudeStats: Equatable, Sendable {
    public var totalSessions = 0
    public var totalMessages = 0
    public var firstSessionDate: String?
    public var lastComputedDate: String?
    public var hourCounts: [Int: Int] = [:]

    /// Claude Code recomputes this only occasionally, so it can lag by weeks.
    /// Anything shown from it has to say when it was last true.
    public var isStale: Bool {
        guard let lastComputedDate,
              let computed = ClaudeStats.dayFormatter.date(from: lastComputedDate)
        else { return true }
        return Date().timeIntervalSince(computed) > 172_800
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/stats-cache.json")
    }

    public static func load(from url: URL = ClaudeStats.defaultURL) -> ClaudeStats? {
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        var stats = ClaudeStats()
        stats.totalSessions = json["totalSessions"] as? Int ?? 0
        stats.totalMessages = json["totalMessages"] as? Int ?? 0
        stats.lastComputedDate = json["lastComputedDate"] as? String
        if let first = json["firstSessionDate"] as? String {
            stats.firstSessionDate = String(first.prefix(10))
        }
        for (hour, count) in (json["hourCounts"] as? [String: Int] ?? [:]) {
            if let hour = Int(hour) { stats.hourCounts[hour] = count }
        }
        return stats
    }
}
