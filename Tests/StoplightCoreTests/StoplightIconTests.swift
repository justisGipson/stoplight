import Testing
import AppKit
@testable import StoplightCore

/// Fixed height so the geometry never depends on the window server.
private let bar: CGFloat = 24

// MARK: - Layout

@Test func housingFitsInsideTheMenuBar() {
    #expect(StoplightIcon.housingHeight(barHeight: bar) <= bar)
    #expect(StoplightIcon.housingHeight(barHeight: bar) == bar - StoplightIcon.inset * 2)
}

@Test func threeLampsPlusGapsAndPaddingExactlyFillTheHousing() {
    // The layout is solved for the bar height rather than scaled to it, so this
    // has to balance exactly — any slop shows up as a lopsided housing.
    let d = StoplightIcon.diameter(barHeight: bar)
    let used = d * 3 + StoplightIcon.gap * 2 + StoplightIcon.padding * 2
    #expect(abs(used - StoplightIcon.housingHeight(barHeight: bar)) < 0.0001)
}

@Test func lampsAreOrderedRedOnTop() {
    // Like a real stoplight, and the fixed slot order the readability depends on.
    let red = StoplightIcon.lampCenterY(.red, barHeight: bar)
    let yellow = StoplightIcon.lampCenterY(.yellow, barHeight: bar)
    let green = StoplightIcon.lampCenterY(.green, barHeight: bar)
    #expect(red > yellow)
    #expect(yellow > green)
}

@Test func lampsAreEvenlySpaced() {
    let red = StoplightIcon.lampCenterY(.red, barHeight: bar)
    let yellow = StoplightIcon.lampCenterY(.yellow, barHeight: bar)
    let green = StoplightIcon.lampCenterY(.green, barHeight: bar)
    #expect(abs((red - yellow) - (yellow - green)) < 0.0001)
}

@Test func everyLampStaysInsideTheHousing() {
    let d = StoplightIcon.diameter(barHeight: bar)
    let top = bar - StoplightIcon.inset
    let bottom = StoplightIcon.inset
    for lamp in Lamp.allCases {
        let centre = StoplightIcon.lampCenterY(lamp, barHeight: bar)
        #expect(centre + d / 2 <= top + 0.0001, "\(lamp) overflows the top")
        #expect(centre - d / 2 >= bottom - 0.0001, "\(lamp) overflows the bottom")
    }
}

@Test func canvasIsWideEnoughForALampPlusItsPadding() {
    #expect(StoplightIcon.canvasWidth(barHeight: bar)
            == StoplightIcon.diameter(barHeight: bar) + StoplightIcon.padding * 2)
}

@Test func layoutStaysValidAcrossPlausibleMenuBarHeights() {
    // The bar is 22pt on older displays and 24pt on current ones, and notched
    // displays report more again.
    for height in stride(from: CGFloat(18), through: CGFloat(40), by: CGFloat(0.5)) {
        #expect(StoplightIcon.diameter(barHeight: height) > 0, "degenerate at \(height)")
        #expect(StoplightIcon.canvasWidth(barHeight: height) > 0, "degenerate at \(height)")
    }
}

// MARK: - Rendering

private struct Energy { var r = 0.0, g = 0.0, b = 0.0, maxAlpha = 0.0 }

/// Renders into a fixed bitmap and sums each channel. Channel totals rather than
/// sampled pixels: the result is independent of backing scale and of where in the
/// canvas a lamp happens to land, so it survives layout tweaks.
@MainActor
private func render(_ state: LightState) -> Energy {
    let w = 16, h = 24, count = w * h * 4
    let bytes = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 8)
    defer { bytes.deallocate() }
    bytes.initializeMemory(as: UInt8.self, repeating: 0, count: count)

    let ctx = CGContext(data: bytes, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // Pin the appearance: housing and unlit lamps derive from labelColor.
    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
        StoplightIcon.draw(state, in: ctx, size: CGSize(width: CGFloat(w), height: CGFloat(h)))
    }

    let px = bytes.assumingMemoryBound(to: UInt8.self)
    var e = Energy()
    for i in stride(from: 0, to: count, by: 4) {
        e.r += Double(px[i]); e.g += Double(px[i + 1]); e.b += Double(px[i + 2])
        e.maxAlpha = max(e.maxAlpha, Double(px[i + 3]))
    }
    return e
}

@Test @MainActor func lightingTheRedLampAddsRedEnergy() {
    #expect(render(LightState(failed: 1)).r > render(LightState()).r)
}

@Test @MainActor func lightingTheGreenLampAddsGreenEnergy() {
    #expect(render(LightState(running: 1)).g > render(LightState()).g)
}

@Test @MainActor func lightingOneLampDoesNotLightTheOthers() {
    let redOnly = render(LightState(failed: 1))
    let greenOnly = render(LightState(running: 1))
    #expect(redOnly.r > greenOnly.r)
    #expect(greenOnly.g > redOnly.g)
}

@Test @MainActor func unlitLampsAreStillDrawn() {
    // The accessibility contract: every slot renders even when dark, so the lit
    // one is identified by position rather than by hue alone.
    let dark = render(LightState())
    let housingAlpha = Double(StoplightIcon.housingColor.alphaComponent) * 255
    let unlitAlpha = Double(StoplightIcon.unlitColor.alphaComponent) * 255
    #expect(dark.maxAlpha > housingAlpha, "nothing brighter than the housing was drawn")
    #expect(dark.maxAlpha >= unlitAlpha * 0.85)
}

@Test @MainActor func imageMatchesTheComputedCanvas() {
    let image = StoplightIcon.image(for: LightState(running: 1))
    #expect(image.size.width == StoplightIcon.canvasWidth())
    #expect(image.size.height == StoplightIcon.barHeight)
}

@Test @MainActor func iconIsNeverRenderedAsATemplate() {
    // Template images get recoloured by AppKit, which would erase the signal.
    #expect(StoplightIcon.image(for: LightState(running: 1)).isTemplate == false)
}
