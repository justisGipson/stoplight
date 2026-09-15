import AppKit

/// Draws the menu bar stoplight at an arbitrary rotation.
///
/// All three lamps are always drawn; unlit ones are dimmed rather than omitted, so
/// "which lamp is lit" reads as brightness at a known slot and never depends on hue.
///
/// Geometry note: the strip is longer than the menu bar is tall, so rotating it
/// upright requires scaling to fit. `scale(at:)` computes the exact factor for any
/// angle, which is what keeps the animation from clipping mid-turn.
enum StoplightIcon {
    static let diameter: CGFloat = 8.5
    static let gap: CGFloat = 3.0
    static let padding: CGFloat = 2.5

    /// Long axis of the housing (3 lamps + gaps + padding).
    static var stripLength: CGFloat { diameter * 3 + gap * 2 + padding * 2 }
    /// Short axis of the housing.
    static var stripThickness: CGFloat { diameter + padding * 2 }
    /// Actual menu bar height — 24pt on modern displays, not the legacy 22.
    static var barHeight: CGFloat { NSStatusBar.system.thickness }

    static func litColor(_ lamp: Lamp) -> NSColor {
        switch lamp {
        case .red:    NSColor(srgbRed: 0.94, green: 0.28, blue: 0.24, alpha: 1)
        case .yellow: NSColor(srgbRed: 0.98, green: 0.74, blue: 0.09, alpha: 1)
        case .green:  NSColor(srgbRed: 0.22, green: 0.78, blue: 0.35, alpha: 1)
        }
    }

    /// Unlit lamps sit brighter than the housing so the slots stay readable.
    static var unlitColor: NSColor { .labelColor.withAlphaComponent(0.30) }
    static var housingColor: NSColor { .labelColor.withAlphaComponent(0.13) }

    // MARK: - Rotation geometry

    /// `angle` is radians clockwise. 0 = horizontal, .pi/2 = upright with red on top.
    static func extent(at angle: CGFloat) -> CGSize {
        let c = abs(cos(angle)), s = abs(sin(angle))
        return CGSize(width:  stripLength * c + stripThickness * s,
                      height: stripLength * s + stripThickness * c)
    }

    /// Largest scale that still fits inside the menu bar at this angle.
    static func scale(at angle: CGFloat, barHeight h: CGFloat = barHeight) -> CGFloat {
        min(1, h / extent(at: angle).height)
    }

    /// Canvas width at this angle. Interpolating it keeps the upright form snug
    /// instead of marooned in ~30px of leftover horizontal dead space.
    static func canvasWidth(at angle: CGFloat, barHeight h: CGFloat = barHeight) -> CGFloat {
        extent(at: angle).width * scale(at: angle, barHeight: h)
    }

    // MARK: - Drawing

    /// - Parameter turn: 0 = horizontal, 1 = fully upright (red on top).
    static func angle(forTurn turn: CGFloat) -> CGFloat { (.pi / 2) * max(0, min(1, turn)) }

    static func image(for state: LightState, turn: CGFloat) -> NSImage {
        let size = NSSize(width: max(canvasWidth(at: angle(forTurn: turn)), 1), height: barHeight)

        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            draw(state, turn: turn, in: ctx, size: size)
            return true
        }
        // Colour is the signal — never let AppKit recolour this as a template.
        image.isTemplate = false
        return image
    }

    /// Renders into any context. Split out from `image(for:turn:)` so tests can
    /// draw into a fixed-size bitmap instead of guessing at backing scale.
    static func draw(_ state: LightState, turn: CGFloat, in ctx: CGContext, size: CGSize) {
        let angle = angle(forTurn: turn)
        let s = scale(at: angle, barHeight: size.height)

        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        // Negative = clockwise in this y-up space, which carries the leftmost
        // lamp (red) to the top. Positive would put green on top.
        ctx.rotate(by: -angle)
        ctx.scaleBy(x: s, y: s)

        // Housing, centred on the origin in unrotated strip space.
        let housing = CGRect(x: -stripLength / 2, y: -stripThickness / 2,
                             width: stripLength, height: stripThickness)
        ctx.setFillColor(housingColor.cgColor)
        ctx.addPath(CGPath(roundedRect: housing,
                           cornerWidth: stripThickness * 0.34,
                           cornerHeight: stripThickness * 0.34,
                           transform: nil))
        ctx.fillPath()

        for lamp in Lamp.allCases {
            let cx = -stripLength / 2 + padding + diameter / 2
                   + CGFloat(lamp.rawValue) * (diameter + gap)
            let color = state.count(lamp) > 0 ? litColor(lamp) : unlitColor
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: cx - diameter / 2, y: -diameter / 2,
                                       width: diameter, height: diameter))
        }
    }
}
