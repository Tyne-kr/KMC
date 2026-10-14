import XCTest
import CoreGraphics
import CSPI
@testable import G309MouseTool

/// macOS 27 DockSwipe payload regression tests. Nothing here posts input.
///
/// Background: macOS 27 stopped reading the legacy CGEvent fields of synthetic dock
/// swipes, which silently killed Space switching (wheel-click + drag did nothing).
/// The fix attaches an IOHIDEvent payload instead. These tests pin the raw values
/// and verify the payload survives a round trip through the system on this OS.
final class DockSwipeHIDTests: XCTestCase {

    // MARK: - Raw values (v1.9.3 lesson: match by value, never by name)

    func testHIDEventTypeValues() {
        XCTAssertEqual(KMCHIDEventTypeVelocity, 9)
        XCTAssertEqual(KMCHIDEventTypeDockSwipe, 23)
    }

    /// Field id = (event type << 16) | index. Expected numbers are the ones MMF
    /// enumerated at runtime from a real trackpad dock swipe on macOS 27.
    func testHIDFieldValues() {
        XCTAssertEqual(KMCHIDFieldDockSwipeMotion, 1_507_329)
        XCTAssertEqual(KMCHIDFieldDockSwipeProgress, 1_507_330)
        XCTAssertEqual(KMCHIDFieldDockSwipeFlavor, 1_507_333)
        XCTAssertEqual(KMCHIDFieldVelocityX, 589_824)
        XCTAssertEqual(KMCHIDFieldVelocityY, 589_825)
        XCTAssertEqual(KMCHIDFieldVelocityZ, 589_826)
    }

    func testGestureAndPhaseValues() {
        XCTAssertEqual(KMCHIDGestureMotionHorizontalX, 1)
        XCTAssertEqual(KMCHIDGestureFlavorDockPrimary, 3)
        XCTAssertEqual(KMCHIDEventPhaseBegan, 1)
        XCTAssertEqual(KMCHIDEventPhaseChanged, 2)
        XCTAssertEqual(KMCHIDEventPhaseEnded, 4)
        XCTAssertEqual(KMCHIDEventPhaseCancelled, 8)
        XCTAssertEqual(KMCHIDEventPhaseShift, 24)
    }

    // MARK: - Path selection

    func testHIDPathSelectedOnMacOS27() {
        if #available(macOS 27, *) {
            XCTAssertTrue(ActionExecutor.usesHIDPayload)
            XCTAssertTrue(KMCDockSwipeHIDPathAvailable(), "SLEventSetIOHIDEvent must resolve on macOS 27")
        } else {
            XCTAssertFalse(ActionExecutor.usesHIDPayload)
        }
    }

    // MARK: - Payload round trip (runs where the SkyLight setter exists)

    func testPayloadRoundTripAllPhases() throws {
        try XCTSkipUnless(KMCDockSwipeHIDPathAvailable(), "SLEventSetIOHIDEvent unavailable on this OS")

        let cases: [(phase: Int, progress: Double, velocity: Double)] = [
            (KMCHIDEventPhaseBegan, -0.1, 0),
            (KMCHIDEventPhaseChanged, -0.8, 0),
            (KMCHIDEventPhaseEnded, -1.5, -150),
            (KMCHIDEventPhaseCancelled, 1.5, 150),
        ]

        for c in cases {
            let event = try XCTUnwrap(KMCCreateDockSwipeHIDEvent(
                UInt32(KMCHIDGestureMotionHorizontalX), UInt16(c.phase), c.progress, c.velocity))
            XCTAssertEqual(event.type.rawValue, 30, "wrapper must be a type-30 CGEvent")

            var info = KMCDockSwipeInfo()
            XCTAssertTrue(KMCInspectDockSwipeHIDEvent(event, &info))
            XCTAssertEqual(Int(info.type), KMCHIDEventTypeDockSwipe)
            XCTAssertEqual(Int(info.phase), c.phase)
            XCTAssertEqual(info.motion, KMCHIDGestureMotionHorizontalX)
            XCTAssertEqual(info.flavor, KMCHIDGestureFlavorDockPrimary)
            // Progress is stored fixed-point (0.1 reads back as 0.0999908).
            XCTAssertEqual(info.progress, c.progress, accuracy: 1e-3)

            let terminal = c.phase == KMCHIDEventPhaseEnded || c.phase == KMCHIDEventPhaseCancelled
            if terminal {
                XCTAssertEqual(info.childCount, 1, "terminal phase must carry a velocity child")
                XCTAssertEqual(Int(info.childType), KMCHIDEventTypeVelocity)
                XCTAssertEqual(info.velocityX, c.velocity, accuracy: 1e-3)
                XCTAssertEqual(info.velocityY, c.velocity, accuracy: 1e-3)
                // Rebound guard (MMF PR #1936/#2077): velocity must point the same way as progress.
                XCTAssertEqual(info.progress.sign, info.velocityX.sign)
            } else {
                XCTAssertEqual(info.childCount, 0)
            }
        }
    }
}
