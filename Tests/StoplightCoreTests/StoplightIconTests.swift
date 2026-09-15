import Testing
import AppKit
@testable import StoplightCore

/// Fixed height so the geometry never depends on the window server.
private let bar: CGFloat = 24

@Test func horizontalOrientationDrawsAtFullScale() {
    #expect(StoplightIcon.scale(at: 0, barHeight: bar) == 1)
}

@Test func uprightOrientationShrinksToFitTheMenuBar() {
    let s = StoplightIcon.scale(at: .pi / 2, barHeight: bar)
    #expect(s < 1)
    // Upright, the strip's long axis is exactly the bar height.
    #expect(abs(StoplightIcon.stripLength * s - bar) < 0.001)
}

@Test func rotationNeverClipsAtAnyAngle() {
    // The invariant that keeps the animation from being cut off partway through
    // the turn, where the diagonal extent is larger than either endpoint.
    for step in 0...100 {
        let turn = CGFloat(step) / 100
        let angle = StoplightIcon.angle(forTurn: turn)
        let height = StoplightIcon.extent(at: angle).height
                   * StoplightIcon.scale(at: angle, barHeight: bar)
        #expect(height <= bar + 0.001, "clipped at turn \(turn)")
    }
}

@Test func uprightIsNarrowerThanHorizontal() {
    #expect(StoplightIcon.canvasWidth(at: .pi / 2, barHeight: bar)
          < StoplightIcon.canvasWidth(at: 0, barHeight: bar))
}

@Test func turnIsClampedToItsEndpoints() {
    #expect(StoplightIcon.angle(forTurn: -5) == 0)
    #expect(StoplightIcon.angle(forTurn: 5) == .pi / 2)
    #expect(StoplightIcon.angle(forTurn: 0) == 0)
}

// MARK: - Rendering

private struct Energy { var r = 0.0, g = 0.0, b = 0.0, maxAlpha = 0.0 }

/// Renders into a fixed bitmap and sums each channel. Channel totals rather than
/// sampled pixels: the result is independent of backing scale and of where in the
/// canvas a lamp happens to land, so it survives layout tweaks.
@MainActor
private func render(_ state: LightState, turn: CGFloat = 0) -> Energy {
    let w = 64, h = 24, count = w * h * 4
    let bytes = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 8)
    defer { bytes.deallocate() }
    bytes.initializeMemory(as: UInt8.self, repeating: 0, count: count)

    let ctx = CGContext(data: bytes, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // Pin the appearance: housing and unlit lamps derive from labelColor.
    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
        StoplightIcon.draw(state, turn: turn, in: ctx,
                           size: CGSize(width: CGFloat(w), height: CGFloat(h)))
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

@Test @MainActor func imageMatchesComputedCanvasWidth() {
    let image = StoplightIcon.image(for: LightState(running: 1), turn: 0)
    #expect(abs(image.size.width - StoplightIcon.canvasWidth(at: 0)) < 0.001)
    #expect(image.size.height == StoplightIcon.barHeight)
}

@Test @MainActor func iconIsNeverRenderedAsATemplate() {
    // Template images get recoloured by AppKit, which would erase the signal.
    #expect(StoplightIcon.image(for: LightState(running: 1), turn: 0).isTemplate == false)
}
