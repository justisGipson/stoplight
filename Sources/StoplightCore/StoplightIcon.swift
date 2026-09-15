import AppKit

/// Draws the menu bar stoplight: an upright housing, red on top.
///
/// Laid out natively at menu bar size rather than scaled down from a horizontal
/// strip, so the lamps land on whole pixels and stay crisp.
///
/// All three lamps are always drawn; unlit ones are dimmed rather than omitted, so
/// "which lamp is lit" reads as brightness at a known slot and never depends on
/// being able to distinguish hue.
enum StoplightIcon {
    /// Breathing room above and below the housing.
    static let inset: CGFloat = 1.0
    /// Housing wall to lamp.
    static let padding: CGFloat = 1.3
    /// Between adjacent lamps.
    static let gap: CGFloat = 1.3

    /// Actual menu bar height — 24pt on modern displays, not the legacy 22.
    static var barHeight: CGFloat { NSStatusBar.system.thickness }

    static func housingHeight(barHeight h: CGFloat = barHeight) -> CGFloat {
        h - inset * 2
    }

    /// Whatever is left over after the housing's padding and gaps, split three ways.
    static func diameter(barHeight h: CGFloat = barHeight) -> CGFloat {
        (housingHeight(barHeight: h) - gap * 2 - padding * 2) / 3
    }

    static func canvasWidth(barHeight h: CGFloat = barHeight) -> CGFloat {
        diameter(barHeight: h) + padding * 2
    }

    /// Centre of a lamp in canvas coordinates, y up. Red sits highest.
    static func lampCenterY(_ lamp: Lamp, barHeight h: CGFloat = barHeight) -> CGFloat {
        let d = diameter(barHeight: h)
        let housingTop = (h + housingHeight(barHeight: h)) / 2
        return housingTop - padding - d / 2 - CGFloat(lamp.rawValue) * (d + gap)
    }

    // MARK: - Colours

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

    // MARK: - Drawing

    static func image(for state: LightState) -> NSImage {
        let size = NSSize(width: canvasWidth(), height: barHeight)
        let image = NSImage(size: size, flipped: false) { _ in
            if let ctx = NSGraphicsContext.current?.cgContext {
                draw(state, in: ctx, size: size)
            }
            return true
        }
        // Colour is the signal — never let AppKit recolour this as a template.
        image.isTemplate = false
        return image
    }

    /// Renders into any context. Split out from `image(for:)` so tests can draw
    /// into a fixed-size bitmap instead of guessing at backing scale.
    static func draw(_ state: LightState, in ctx: CGContext, size: CGSize) {
        let h = size.height
        let d = diameter(barHeight: h)
        let housing = CGRect(x: (size.width - canvasWidth(barHeight: h)) / 2,
                             y: inset,
                             width: canvasWidth(barHeight: h),
                             height: housingHeight(barHeight: h))

        ctx.setFillColor(housingColor.cgColor)
        ctx.addPath(CGPath(roundedRect: housing,
                           cornerWidth: canvasWidth(barHeight: h) * 0.34,
                           cornerHeight: canvasWidth(barHeight: h) * 0.34,
                           transform: nil))
        ctx.fillPath()

        for lamp in Lamp.allCases {
            let color = state.count(lamp) > 0 ? litColor(lamp) : unlitColor
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: housing.midX - d / 2,
                                       y: lampCenterY(lamp, barHeight: h) - d / 2,
                                       width: d, height: d))
        }
    }
}
