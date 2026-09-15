import SwiftUI

/// Hover detail: the full-size stoplight, plus a row per live session.
struct PopoverView: View {
    let state: LightState
    let sessions: [Session]
    let casualties: [Casualty]
    let snapshots: [String: TranscriptSnapshot]
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // The menu bar lamps are ~5px. This is where the stoplight is legible.
            upright

            VStack(alignment: .leading, spacing: 8) {
                Text(state.summary)
                    .font(.system(size: 13, weight: .semibold))

                if sessions.isEmpty && casualties.isEmpty {
                    Text("No Claude Code sessions running")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(sessions) { session in
                            row(for: session)
                        }
                        ForEach(casualties.filter { $0.isActive(now: now) }) { casualty in
                            casualtyRow(for: casualty)
                        }
                    }
                }
            }
            .frame(width: 230, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    private func row(for session: Session) -> some View {
        let snapshot = snapshots[session.sessionId]
        let bucket = session.bucket(now: now, snapshot: snapshot)
        return HStack(spacing: 7) {
            Circle()
                .fill(Color(nsColor: color(for: bucket)))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.folder)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(detail(for: session, bucket: bucket, snapshot: snapshot))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 1) {
                if let age = session.age(now: now) {
                    Text(age)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if let tokens = snapshot?.contextTokens {
                    Text(compact(tokens))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Context size, as a token count you can read at a glance.
    private func compact(_ tokens: Int) -> String {
        tokens >= 1000 ? String(format: "%.0fk", Double(tokens) / 1000) : "\(tokens)"
    }

    private func casualtyRow(for casualty: Casualty) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(nsColor: StoplightIcon.litColor(.red)))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(casualty.folder)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.head)
                Text("stopped while working")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Text(age(since: casualty.diedAt))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private func age(since date: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "\(Int(seconds))s"
        case ..<3600: return "\(Int(seconds / 60))m"
        default: return "\(Int(seconds / 3600))h"
        }
    }

    private func color(for bucket: Bucket) -> NSColor {
        switch bucket {
        case .failed: StoplightIcon.litColor(.red)
        case .attention: StoplightIcon.litColor(.yellow)
        case .running: StoplightIcon.litColor(.green)
        case .idle: StoplightIcon.unlitColor
        }
    }

    private func detail(for session: Session,
                        bucket: Bucket,
                        snapshot: TranscriptSnapshot?) -> String {
        switch bucket {
        case .failed:
            if let status = snapshot?.lastErrorStatus, status > 0 { return "API error \(status)" }
            return "failed"
        case .attention:
            // Claude Code's own words: "permission prompt" or "input needed".
            if case .waiting(let reason) = session.status, let reason { return reason }
            return "finished — waiting for you"
        case .running:
            if let tool = snapshot?.currentTool { return "running \(tool)" }
            return session.status == .shell ? "running a command" : "working"
        case .idle:
            return "idle"
        }
    }

    private var upright: some View {
        VStack(spacing: 5) {
            ForEach(Lamp.allCases, id: \.self) { lamp in
                Circle()
                    .fill(Color(nsColor: state.count(lamp) > 0
                                ? StoplightIcon.litColor(lamp)
                                : StoplightIcon.unlitColor))
                    .frame(width: 22, height: 22)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: StoplightIcon.housingColor))
        )
    }
}
