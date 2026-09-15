import Foundation
import CoreServices

public struct SessionDiagnostics: Equatable, Sendable {
    public var filesSeen = 0
    public var live = 0
    public var stale = 0
    public var unreadable = 0
    public var unknownStatuses: [String] = []
    public var claudeVersion = "unknown"

    /// Shown in the menu. When a future Claude Code version changes the on-disk
    /// format, this line is how you find out in seconds instead of wondering why
    /// the lamps went dark.
    public var summary: String {
        var parts = ["\(live)/\(filesSeen) sessions"]
        if stale > 0 { parts.append("\(stale) stale") }
        if unreadable > 0 { parts.append("\(unreadable) unreadable") }
        if !unknownStatuses.isEmpty {
            parts.append("unknown: \(unknownStatuses.joined(separator: ", "))")
        }
        parts.append("Claude Code \(claudeVersion)")
        return parts.joined(separator: " · ")
    }
}

/// Watches `~/.claude/sessions/` and keeps a live list of sessions.
///
/// Push-based via FSEvents, so there is no polling timer and no idle CPU cost.
/// A plain vnode watch would not do: session files are rewritten in place when a
/// status changes, and a directory vnode only reports entries appearing and
/// disappearing, not edits to the files inside.
@MainActor
public final class SessionWatcher {
    public private(set) var sessions: [Session] = []
    public private(set) var diagnostics = SessionDiagnostics()
    public var onChange: (() -> Void)?

    public let directory: URL
    private var stream: FSEventStreamRef?

    nonisolated public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/sessions", directoryHint: .isDirectory)
    }

    public init(directory: URL = SessionWatcher.defaultDirectory) {
        self.directory = directory
    }

    public func start() {
        reload()
        guard stream == nil else { return }

        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)

        // A C function pointer cannot capture, so `self` travels in the context.
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<SessionWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.reload() }
        }

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,   // coalesce bursts; a status flip writes several times
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                                   | kFSEventStreamCreateFlagNoDefer)
        ) else { return }

        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
        stream = created
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    public func reload() {
        let (found, diagnostics) = Self.scan(directory: directory)
        guard found != sessions || diagnostics != self.diagnostics else { return }
        sessions = found
        self.diagnostics = diagnostics
        onChange?()
    }

    /// Hand it a directory, get back what is in it. Kept free of instance state and
    /// with process liveness injectable so it can be tested against a fixture.
    nonisolated public static func scan(
        directory: URL,
        isAlive: (pid_t) -> Bool = SessionWatcher.processExists
    ) -> ([Session], SessionDiagnostics) {
        var diagnostics = SessionDiagnostics()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
        diagnostics.filesSeen = urls.count

        var live: [Session] = []
        var unknown: Set<String> = []

        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let session = SessionDecoder.session(from: data) else {
                diagnostics.unreadable += 1
                continue
            }
            if case .unknown(let raw) = session.status { unknown.insert(raw) }
            // Session files outlive their process; drop the orphans.
            guard isAlive(session.pid) else {
                diagnostics.stale += 1
                continue
            }
            live.append(session)
        }

        diagnostics.live = live.count
        diagnostics.unknownStatuses = unknown.sorted()
        diagnostics.claudeVersion = live.first?.version ?? "unknown"

        return (live.sorted(by: displayOrder), diagnostics)
    }

    /// Busy first, then most recently active, then by pid so ordering is stable.
    nonisolated static func displayOrder(_ a: Session, _ b: Session) -> Bool {
        if (a.status == .busy) != (b.status == .busy) { return a.status == .busy }
        let left = a.statusUpdatedAt ?? .distantPast
        let right = b.statusUpdatedAt ?? .distantPast
        if left != right { return left > right }
        return a.pid < b.pid
    }

    /// EPERM means the process exists but belongs to someone else.
    nonisolated public static func processExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
