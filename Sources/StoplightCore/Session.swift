import Foundation

/// A live Claude Code session, as Claude Code itself reports it.
public struct Session: Equatable, Identifiable, Sendable {
    public let pid: pid_t
    public let sessionId: String
    public let cwd: String
    public let name: String
    public let kind: String
    public let version: String
    public let status: SessionStatus
    public let startedAt: Date?
    public let statusUpdatedAt: Date?

    public var id: pid_t { pid }

    /// Last path component of `cwd` — what you actually recognise a session by.
    public var folder: String {
        let leaf = URL(fileURLWithPath: cwd).lastPathComponent
        return leaf.isEmpty ? cwd : leaf
    }
}

/// Claude Code writes `busy` and `idle`. Anything else is kept verbatim rather
/// than guessed at, and surfaces in diagnostics.
public enum SessionStatus: Equatable, Sendable {
    case busy
    case idle
    case unknown(String)

    public init(raw: String?) {
        switch raw {
        case "busy": self = .busy
        case "idle": self = .idle
        case let other: self = .unknown(other ?? "")
        }
    }
}

/// A session whose process vanished while it was still working.
///
/// A session shutting down cleanly goes `idle` first, so disappearing straight out
/// of `busy` means it was killed, crashed, or had its terminal closed mid-task.
/// That is the only failure signal available without hook events, and it is a real
/// one — but it is inherently a memory: the process is gone and its file with it,
/// so the casualty is held here until it expires or is dismissed.
public struct Casualty: Equatable, Identifiable, Sendable {
    public let pid: pid_t
    public let sessionId: String
    public let folder: String
    public let diedAt: Date

    public var id: pid_t { pid }

    public func expiry(window: TimeInterval = Casualty.defaultWindow) -> Date {
        diedAt.addingTimeInterval(window)
    }

    public func isActive(now: Date = Date(), window: TimeInterval = Casualty.defaultWindow) -> Bool {
        expiry(window: window) > now
    }

    /// Longer than the attention window: a crash you missed because you stepped
    /// away still deserves to be on screen when you get back.
    public static let defaultWindow: TimeInterval = 1800
}

/// Which lamp a session contributes to.
public enum Bucket: Equatable, Sendable {
    case failed, attention, running, idle
}

extension Session {
    /// A session that just finished still wants you — a twenty-minute task landing
    /// is the most useful thing this app can say. But it should not ask forever, so
    /// attention decays back to idle after `recentWindow`.
    ///
    /// Nothing produces `.failed` yet; that needs hook events (milestone 3).
    public func bucket(now: Date = Date(),
                       recentWindow: TimeInterval = Session.defaultRecentWindow) -> Bucket {
        switch status {
        case .busy:
            return .running
        case .idle:
            guard let finished = statusUpdatedAt,
                  now.timeIntervalSince(finished) < recentWindow else { return .idle }
            return .attention
        case .unknown:
            // Never invent a colour for a status we do not recognise.
            return .idle
        }
    }

    /// How long a just-finished session keeps asking for attention.
    public static let defaultRecentWindow: TimeInterval = 300

    /// When this session stops counting as attention, if it ever does.
    public func attentionExpiry(recentWindow: TimeInterval = Session.defaultRecentWindow) -> Date? {
        guard case .idle = status, let finished = statusUpdatedAt else { return nil }
        return finished.addingTimeInterval(recentWindow)
    }
}

// MARK: - Decoding

/// Reads `~/.claude/sessions/<pid>.json`.
///
/// Deliberately tolerant: that directory is a Claude Code implementation detail,
/// not a public API, and its shape can change between versions. Only `pid` and
/// `sessionId` are required; every other field degrades to a default, and a file
/// that cannot be read is skipped rather than being allowed to take down the app.
public enum SessionDecoder {
    public static func session(from data: Data) -> Session? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              let rawPid = json["pid"] as? Int, rawPid > 0,
              let sessionId = json["sessionId"] as? String, !sessionId.isEmpty
        else { return nil }

        let cwd = json["cwd"] as? String ?? ""
        return Session(
            pid: pid_t(rawPid),
            sessionId: sessionId,
            cwd: cwd,
            name: json["name"] as? String ?? URL(fileURLWithPath: cwd).lastPathComponent,
            kind: json["kind"] as? String ?? "unknown",
            version: json["version"] as? String ?? "unknown",
            status: SessionStatus(raw: json["status"] as? String),
            startedAt: millisecondDate(json["startedAt"]),
            statusUpdatedAt: millisecondDate(json["statusUpdatedAt"])
        )
    }

    /// Timestamps are milliseconds since the epoch.
    static func millisecondDate(_ value: Any?) -> Date? {
        guard let milliseconds = value as? Double, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}

// MARK: - Aggregation

extension LightState {
    public init(sessions: [Session],
                casualties: [Casualty] = [],
                now: Date = Date(),
                recentWindow: TimeInterval = Session.defaultRecentWindow,
                casualtyWindow: TimeInterval = Casualty.defaultWindow) {
        self.init()
        for session in sessions {
            switch session.bucket(now: now, recentWindow: recentWindow) {
            case .running: running += 1
            case .attention: attention += 1
            case .failed: failed += 1
            case .idle: break
            }
        }
        failed += casualties.filter { $0.isActive(now: now, window: casualtyWindow) }.count
    }
}

extension Session {
    /// Compact time since the last status change, e.g. "4m".
    public func age(now: Date = Date()) -> String? {
        guard let changed = statusUpdatedAt else { return nil }
        let seconds = max(0, now.timeIntervalSince(changed))
        switch seconds {
        case ..<60: return "\(Int(seconds))s"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }
}
