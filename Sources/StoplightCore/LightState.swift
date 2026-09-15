import Foundation

/// Which lamp. The raw value is the slot, left to right, and never changes —
/// position is the primary visual encoding, not hue.
enum Lamp: Int, CaseIterable {
    case red = 0, yellow, green
}

/// What the three lamps are showing.
///
/// Counts rather than booleans: a lamp is lit when its count is non-zero, and the
/// popover needs the number anyway. The three are independent — all can be lit.
struct LightState: Equatable {
    var failed = 0
    var attention = 0
    var running = 0

    func count(_ lamp: Lamp) -> Int {
        switch lamp {
        case .red: failed
        case .yellow: attention
        case .green: running
        }
    }

    var summary: String {
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if attention > 0 { parts.append("\(attention) need\(attention == 1 ? "s" : "") attention") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? "No active Claude sessions" : parts.joined(separator: ", ")
    }
}

extension Lamp {
    var label: String {
        switch self {
        case .red: "Failed"
        case .yellow: "Needs attention"
        case .green: "Running"
        }
    }
}
