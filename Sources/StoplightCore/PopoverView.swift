import SwiftUI

/// Hover detail: the full-size stoplight, plus a row per live session.
struct PopoverView: View {
    let state: LightState
    let sessions: [Session]
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // The menu bar lamps are ~5px. This is where the stoplight is legible.
            upright

            VStack(alignment: .leading, spacing: 8) {
                Text(state.summary)
                    .font(.system(size: 13, weight: .semibold))

                if sessions.isEmpty {
                    Text("No Claude Code sessions running")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(sessions) { session in
                            row(for: session)
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
        let bucket = session.bucket(now: now)
        return HStack(spacing: 7) {
            Circle()
                .fill(Color(nsColor: color(for: bucket)))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.folder)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(detail(for: session, bucket: bucket))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if let age = session.age(now: now) {
                Text(age)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
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

    private func detail(for session: Session, bucket: Bucket) -> String {
        switch bucket {
        case .running: "working"
        case .attention: "waiting for you"
        case .failed: "failed"
        case .idle: "idle"
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
