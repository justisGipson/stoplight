import AppKit
import UserNotifications

/// Posts the notifications the menu bar cannot.
///
/// The lamps only help while you are looking at them. A session that starts
/// waiting on a permission prompt while you are in another app is exactly the case
/// this app exists for and exactly the case the menu bar misses, so those
/// transitions get a real notification.
///
/// Every notification is edge-triggered and deduplicated: they fire when something
/// *changes*, never on every refresh.
@MainActor
public final class Notifier {
    public static let shared = Notifier()

    private var authorized = false
    private var requested = false

    /// What we last told the user about each session.
    private var announcedWaiting: Set<String> = []
    private var announcedCrash: Set<pid_t> = []
    private var announcedRateLimit: Set<String> = []
    private var announcedCost: Set<String> = []
    private var announcedStale: Set<String> = []

    public var isEnabled = true
    /// Notify once when a session's cost passes this. Zero disables it.
    public var costThreshold = 5.0
    /// Nudge about sessions left idle this long.
    public var staleAfter: TimeInterval = 3 * 86_400

    private init() {}

    public func requestAuthorization() {
        guard !requested else { return }
        requested = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                Task { @MainActor in self.authorized = granted }
            }
    }

    private func post(id: String, title: String, body: String) {
        guard isEnabled, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Edges

    public func reconcile(sessions: [Session],
                          casualties: [Casualty],
                          snapshots: [String: TranscriptSnapshot],
                          now: Date = Date()) {
        var waitingNow: Set<String> = []

        for session in sessions {
            let snapshot = snapshots[session.sessionId]

            if case .waiting(let reason) = session.status {
                waitingNow.insert(session.sessionId)
                if announcedWaiting.insert(session.sessionId).inserted {
                    post(id: "waiting-\(session.sessionId)",
                         title: "\(session.folder) needs you",
                         body: reason ?? "Waiting for input")
                }
            }

            if let limit = snapshot?.rateLimit, limit.isActive(now: now),
               announcedRateLimit.insert(session.sessionId).inserted {
                post(id: "ratelimit-\(session.sessionId)",
                     title: "\(session.folder) is rate limited",
                     body: Notifier.resetDescription(limit))
            }

            if costThreshold > 0, let cost = snapshot?.costUSD, cost >= costThreshold,
               announcedCost.insert(session.sessionId).inserted {
                post(id: "cost-\(session.sessionId)",
                     title: "\(session.folder) passed $\(Int(costThreshold))",
                     body: String(format: "This session has cost $%.2f so far.", cost))
            }

            if case .idle = session.status, let since = session.statusUpdatedAt,
               now.timeIntervalSince(since) > staleAfter,
               announcedStale.insert(session.sessionId).inserted {
                let days = Int(now.timeIntervalSince(since) / 86_400)
                post(id: "stale-\(session.sessionId)",
                     title: "\(session.folder) has been idle \(days) days",
                     body: "Still running. Close it if you are done with it.")
            }
        }

        // Let a session announce itself again next time it needs something.
        announcedWaiting.formIntersection(waitingNow)

        for casualty in casualties where announcedCrash.insert(casualty.pid).inserted {
            post(id: "crash-\(casualty.pid)",
                 title: "\(casualty.folder) stopped while working",
                 body: "The session ended mid-task.")
        }
    }

    nonisolated static func resetDescription(_ limit: RateLimit) -> String {
        guard let resetsAt = limit.resetsAt else { return "Limit reached." }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = Calendar.current.isDateInToday(resetsAt) ? .none : .short
        let kind = limit.type?.replacingOccurrences(of: "_", with: " ") ?? "rate"
        return "The \(kind) limit resets at \(formatter.string(from: resetsAt))."
    }
}
