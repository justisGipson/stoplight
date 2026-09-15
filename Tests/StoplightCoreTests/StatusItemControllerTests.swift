import Testing
import AppKit
@testable import StoplightCore

@Test @MainActor func trackingSelectorsAreRegisteredUnderTheirAppKitNames() {
    // Regression: on a class that is not an NSResponder, Swift maps
    // `mouseEntered(with:)` to the selector `mouseEnteredWith:`. NSTrackingArea
    // only ever calls `mouseEntered:`, so hover silently does nothing — no crash,
    // no warning. The explicit @objc(mouseEntered:) is what connects them.
    #expect(StatusItemController.instancesRespond(to: Selector("mouseEntered:")))
    #expect(StatusItemController.instancesRespond(to: Selector("mouseExited:")))
}

@Test @MainActor func trackingSelectorsAreNotOnlyTheirSwiftMangledNames() {
    // Guards the inverse: if someone drops the explicit selector, these appear
    // instead and the test above starts failing for a reason that is easy to miss.
    #expect(StatusItemController.instancesRespond(to: Selector("mouseEnteredWith:")) == false)
    #expect(StatusItemController.instancesRespond(to: Selector("mouseExitedWith:")) == false)
}
