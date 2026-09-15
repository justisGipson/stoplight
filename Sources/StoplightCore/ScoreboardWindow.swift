import AppKit
import SwiftUI

@MainActor
final class ScoreboardModel: ObservableObject {
    @Published var summary: ScoreboardSummary?
    @Published var stats: ClaudeStats?
    @Published var isLoading = false

    func load() {
        guard !isLoading else { return }
        isLoading = true
        let root = TranscriptReader.defaultProjectsRoot

        Task {
            let summary = await Task.detached(priority: .userInitiated) {
                var store = ScoreboardStore.load()
                let built = ScoreboardBuilder.build(projectsRoot: root, store: &store)
                store.save()
                return built
            }.value

            self.summary = summary
            self.stats = ClaudeStats.load()
            self.isLoading = false
        }
    }
}

/// Opens and reuses the stats window. The app is an accessory, so it has to
/// activate itself for the window to come forward — acceptable here because
/// opening it is an explicit click, unlike the hover panel.
@MainActor
final class ScoreboardWindowController {
    private var window: NSWindow?
    private let model = ScoreboardModel()

    func show() {
        model.load()

        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Stoplight — Usage"
        window.contentView = NSHostingView(rootView: ScoreboardView(model: model))
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - View

struct ScoreboardView: View {
    @ObservedObject var model: ScoreboardModel

    /// One hue for magnitude. These bars are a single series, so there is no
    /// categorical palette to assign and nothing for colour to identify —
    /// length carries the whole message.
    private static let bar = Color(nsColor: NSColor(srgbRed: 0.30, green: 0.55, blue: 0.92, alpha: 1))

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let summary = model.summary, !summary.isEmpty {
                    tiles(summary)
                    ranking("By project", rows: summary.projects.map {
                        (name: $0.folder, value: $0.costUSD,
                         detail: "\($0.sessions) session\($0.sessions == 1 ? "" : "s") · \(compact($0.tokens)) tokens")
                    })
                    ranking("By model", rows: summary.models.map {
                        (name: $0.model, value: $0.costUSD, detail: "\(compact($0.tokens)) tokens")
                    })
                    footer(summary)
                } else if model.isLoading {
                    Text("Reading transcripts…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text("No usage data found in ~/.claude/projects")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.load() }
    }

    // MARK: Headline numbers — a stat tile, not a chart

    private func tiles(_ summary: ScoreboardSummary) -> some View {
        HStack(alignment: .top, spacing: 26) {
            tile(currency(summary.totalCostUSD), "total cost")
            tile(compact(summary.totalTokens), "tokens")
            tile("\(summary.sessions)", "sessions")
            tile("\(summary.crashes)", "crashed", warn: summary.crashes > 0)
        }
    }

    private func tile(_ value: String, _ label: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 24, weight: .medium, design: .rounded))
                // Status colour is reserved and never stands alone — the word
                // "crashed" underneath is what actually carries the meaning.
                .foregroundStyle(warn ? Color(nsColor: StoplightIcon.litColor(.red)) : .primary)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Rankings — single-series magnitude bars

    private func ranking(_ title: String,
                         rows: [(name: String, value: Double, detail: String)]) -> some View {
        let peak = rows.map(\.value).max() ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            if rows.isEmpty {
                Text("nothing recorded yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(rows.prefix(10), id: \.name) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.name)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer(minLength: 12)
                                // Values wear text ink, never the bar's colour.
                                Text(currency(row.value))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            bar(fraction: peak > 0 ? row.value / peak : 0)
                            Text(row.detail)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func bar(fraction: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                // Rounded at the data end, square at the baseline.
                UnevenRoundedRectangle(
                    topLeadingRadius: 0, bottomLeadingRadius: 0,
                    bottomTrailingRadius: 4, topTrailingRadius: 4, style: .continuous)
                    .fill(Self.bar)
                    .frame(width: max(2, geometry.size.width * fraction))
            }
        }
        .frame(height: 7)
    }

    // MARK: Provenance

    private func footer(_ summary: ScoreboardSummary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            Text("\(summary.linesAdded) lines added · \(summary.linesRemoved) removed · "
               + "\(duration(summary.toolTimeMs)) in tools")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("\(summary.transcriptsWithCost) of \(summary.transcriptsSeen) transcripts carry cost data")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            if let stats = model.stats, let computed = stats.lastComputedDate {
                // Claude Code's own cache lags, so never present it as current.
                Text("Claude Code reports \(stats.totalSessions) sessions and "
                   + "\(stats.totalMessages) messages, last recomputed \(computed)"
                   + (stats.isStale ? " — stale" : ""))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Formatting

    private func currency(_ value: Double) -> String {
        value >= 100 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    private func compact(_ value: Int) -> String {
        switch value {
        case ..<1_000: "\(value)"
        case ..<1_000_000: String(format: "%.1fk", Double(value) / 1_000)
        case ..<1_000_000_000: String(format: "%.1fM", Double(value) / 1_000_000)
        default: String(format: "%.1fB", Double(value) / 1_000_000_000)
        }
    }

    private func duration(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}
