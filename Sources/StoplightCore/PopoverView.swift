import SwiftUI

/// Hover detail: the full-size stoplight, plus a row per live session.
struct PopoverView: View {
    let state: LightState
    let sessions: [Session]
    let casualties: [Casualty]
    let snapshots: [String: TranscriptSnapshot]
    let now: Date
    let fontScale: Double
    let onSelect: (Session) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // The menu bar lamps are ~5px. This is where the stoplight is legible.
            upright

            VStack(alignment: .leading, spacing: 8) {
                Text(state.summary)
                    .font(scaled(13, .semibold))

                if sessions.isEmpty && casualties.isEmpty {
                    Text("No Claude Code sessions running")
                        .font(scaled(11))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sessions) { session in
                            HoverRow(action: { onSelect(session) },
                                     hint: "Bring this session's terminal to the front") {
                                sessionRow(session)
                            }
                        }
                        ForEach(casualties.filter { $0.isActive(now: now) }) { casualty in
                            HoverRow(action: nil, hint: nil) { casualtyRow(casualty) }
                        }
                    }
                    .padding(.horizontal, -6)
                }
            }
            .frame(width: 230 * fontScale, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    // MARK: - Rows

    private func sessionRow(_ session: Session) -> some View {
        let snapshot = snapshots[session.sessionId]
        let bucket = session.bucket(now: now, snapshot: snapshot)
        return HStack(spacing: 7) {
            Circle()
                .fill(Color(nsColor: color(for: bucket)))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(session.folder)
                        .font(scaled(12, .medium))
                        .lineLimit(1)
                        .truncationMode(.head)
                    if let branch = snapshot?.gitBranch {
                        Text(branch)
                            .font(scaled(9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if let mode = snapshot?.permissionMode, mode != "default" {
                        Text(mode)
                            .font(scaled(8, .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.10)))
                    }
                }
                Text(detail(for: session, bucket: bucket, snapshot: snapshot))
                    .font(scaled(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 1) {
                if let age = session.age(now: now) {
                    Text(age)
                        .font(scaled(10, .regular, .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if let tokens = snapshot?.contextTokens {
                    Text(compact(tokens))
                        .font(scaled(9, .regular, .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func casualtyRow(_ casualty: Casualty) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(nsColor: StoplightIcon.litColor(.red)))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(casualty.folder)
                    .font(scaled(12, .medium))
                    .lineLimit(1)
                    .truncationMode(.head)
                Text("stopped while working")
                    .font(scaled(10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Text(age(since: casualty.diedAt))
                .font(scaled(10, .regular, .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Pieces

    private var upright: some View {
        VStack(spacing: 5) {
            ForEach(Lamp.allCases, id: \.self) { lamp in
                Circle()
                    .fill(Color(nsColor: state.count(lamp) > 0
                                ? StoplightIcon.litColor(lamp)
                                : StoplightIcon.unlitColor))
                    .frame(width: 22 * fontScale, height: 22 * fontScale)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: StoplightIcon.housingColor))
        )
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
            if let limit = snapshot?.rateLimit, limit.isActive(now: now) {
                return Notifier.resetDescription(limit).replacingOccurrences(
                    of: "The ", with: "").replacingOccurrences(of: " limit resets", with: " limit until")
                    .replacingOccurrences(of: " at ", with: " ")
                    .replacingOccurrences(of: ".", with: "")
            }
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

    // MARK: - Formatting

    private func scaled(_ size: CGFloat,
                        _ weight: Font.Weight = .regular,
                        _ design: Font.Design = .default) -> Font {
        .system(size: size * fontScale, weight: weight, design: design)
    }

    private func compact(_ tokens: Int) -> String {
        tokens >= 1000 ? String(format: "%.0fk", Double(tokens) / 1000) : "\(tokens)"
    }

    private func age(since date: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "\(Int(seconds))s"
        case ..<3600: return "\(Int(seconds / 60))m"
        default: return "\(Int(seconds / 3600))h"
        }
    }
}

/// An invisible button: no chrome until the pointer is over it, then a soft
/// highlight and a pointing cursor. Rows with no action stay inert.
private struct HoverRow<Content: View>: View {
    let action: (() -> Void)?
    let hint: String?
    @ViewBuilder var content: Content

    @State private var isHovering = false

    private var isInteractive: Bool { action != nil }

    var body: some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovering && isInteractive ? 0.10 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering in
                guard isInteractive else { return }
                isHovering = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onTapGesture { action?() }
            .help(hint ?? "")
    }
}
