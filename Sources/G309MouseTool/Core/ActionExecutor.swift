import Cocoa
import CSPI
import os

/// Executes macOS actions in response to mouse gestures.
/// Uses synthetic DockSwipe events (reverse-engineered from macOS internals)
/// to trigger native Space switching with the same animation as a three-finger trackpad swipe.
///
/// Two encodings, chosen by OS version:
/// - macOS ≤ 26: undocumented CGEvent fields (legacy path below).
/// - macOS 27+:  an IOHIDEvent payload attached to the CGEvent. macOS 27 ignores the
///   legacy fields entirely (A/B verified on 27.0.1: legacy = no Space change, payload = switch).
///
/// Reference: Mac Mouse Fix (noah-nuebling/mac-mouse-fix) TouchSimulator.m,
/// macOS 27 fix f92d2d53a, PR #1936 / #2077 (progress + velocity sign normalization).
enum ActionExecutor {

    // MARK: - Pre-computed CGEventField constants (undocumented fields)
    // CGEventField(rawValue:) returns optional; these are validated once at static init.
    // If Apple ever removes a field ID, the app will log an error rather than crash.

    private static let fieldEventType       = CGEventField(rawValue: 55)
    private static let fieldSubtype         = CGEventField(rawValue: 110)
    private static let fieldPhase           = CGEventField(rawValue: 132)
    private static let fieldPhaseDup        = CGEventField(rawValue: 134)
    private static let fieldOriginOffset    = CGEventField(rawValue: 124)
    private static let fieldEncodedOffset   = CGEventField(rawValue: 135)
    private static let fieldDockSwipeType   = CGEventField(rawValue: 123)
    private static let fieldDockSwipeTypeDup = CGEventField(rawValue: 165)
    private static let fieldWeirdType       = CGEventField(rawValue: 119)
    private static let fieldWeirdTypeDup    = CGEventField(rawValue: 139)
    private static let fieldConstant41      = CGEventField(rawValue: 41)
    private static let fieldInverted        = CGEventField(rawValue: 136)
    private static let fieldExitSpeed1      = CGEventField(rawValue: 129)
    private static let fieldExitSpeed2      = CGEventField(rawValue: 130)

    // MARK: - Constants

    private static let kEventTypeMagnify: Int64 = 30
    private static let kEventTypeGesture: Int64 = 29
    private static let kDockSwipeSubtype: Int64 = 23
    private static let kDockSwipeHorizontal: Int64 = 1
    private static let kPhaseBegan: Int64 = 1
    private static let kPhaseChanged: Int64 = 2
    private static let kPhaseEnded: Int64 = 4
    private static let kMagicConstant: Double = 33231.0

    /// Horizontal type encoded as: UInt32(1) → Float32 bits → Double
    private static let weirdHorizontalTypeValue: Double = {
        var typeVal: UInt32 = 1
        var f: Float32 = 0
        memcpy(&f, &typeVal, 4)
        return Double(f)
    }()

    // MARK: - Encoding selection

    static let usesHIDPayload: Bool = {
        if #available(macOS 27, *) { return true }
        return false
    }()

    /// One-line summary for the launch log (lets a captured stderr confirm the active path).
    static var diagnosticDescription: String {
        guard usesHIDPayload else { return "legacy CGEvent fields (macOS ≤ 26)" }
        return KMCDockSwipeHIDPathAvailable()
            ? "IOHIDEvent payload (macOS 27+), SLEventSetIOHIDEvent resolved"
            : "IOHIDEvent payload (macOS 27+) — SLEventSetIOHIDEvent MISSING, Space switching disabled"
    }

    /// Touched only on swipeQueue.
    private static var didLogHIDFailure = false

    // MARK: - Public API

    /// Serial queue: DockSwipe phase sequences must never interleave.
    /// Two overlapping began→changed→ended streams (continuous swipe, or a
    /// quick re-trigger within ~0.5s) corrupt the Dock's gesture state machine
    /// — the exact "stuck Space" bug the re-send workaround exists to prevent.
    private static let swipeQueue = DispatchQueue(label: "com.jc.kmc.dockswipe", qos: .userInteractive)

    /// Generation counter: each swipe invalidates the previous swipe's pending
    /// stuck-bug re-sends, so a stale `ended` (wrong offset sign) can't land
    /// in the middle of the next gesture's phase stream.
    private static let swipeGeneration = OSAllocatedUnfairLock(initialState: UInt64(0))

    static func executeSpaceSwitch(direction: GestureAction) {
        let sign: Double = (direction == .swipeRight) ? -1.0 : 1.0

        #if DEBUG
        fputs("[ActionExecutor] executeSpaceSwitch: \(direction) sign=\(sign)\n", stderr)
        #endif

        let myGeneration = swipeGeneration.withLock { gen -> UInt64 in
            gen += 1
            return gen
        }

        swipeQueue.async {
            let steps: [(phase: Int64, offset: Double)] = [
                (kPhaseBegan,   sign * 0.1),
                (kPhaseChanged, sign * 0.4),
                (kPhaseChanged, sign * 0.8),
                (kPhaseChanged, sign * 1.2),
            ]

            for step in steps {
                postDockSwipeEvent(phase: step.phase, originOffset: step.offset, type: kDockSwipeHorizontal)
                usleep(15000)
            }

            let finalOffset = sign * 1.5
            postDockSwipeEvent(phase: kPhaseEnded, originOffset: finalOffset, type: kDockSwipeHorizontal)

            // Stuck-bug workaround (Mac Mouse Fix): re-send end events.
            // Scheduled (not slept) so the serial queue frees up for the next
            // gesture immediately; skipped if a newer gesture has started.
            for delay in [0.2, 0.5] {
                swipeQueue.asyncAfter(deadline: .now() + delay) {
                    guard swipeGeneration.withLock({ $0 }) == myGeneration else { return }
                    postDockSwipeEvent(phase: kPhaseEnded, originOffset: finalOffset, type: kDockSwipeHorizontal)
                }
            }

            #if DEBUG
            fputs("[ActionExecutor] DockSwipe completed: \(direction == .swipeRight ? "→" : "←")\n", stderr)
            #endif
        }
    }

    // MARK: - DockSwipe Event Posting

    private static func postDockSwipeEvent(phase: Int64, originOffset: Double, type: Int64) {
        if usesHIDPayload {
            postDockSwipeEventHID(phase: phase, originOffset: originOffset, type: type)
            return
        }

        // Validate that undocumented fields are available
        guard let fEventType = fieldEventType, let fSubtype = fieldSubtype,
              let fPhase = fieldPhase, let fPhaseDup = fieldPhaseDup,
              let fOriginOffset = fieldOriginOffset, let fEncodedOffset = fieldEncodedOffset,
              let fDockSwipeType = fieldDockSwipeType, let fDockSwipeTypeDup = fieldDockSwipeTypeDup,
              let fWeirdType = fieldWeirdType, let fWeirdTypeDup = fieldWeirdTypeDup,
              let fConstant41 = fieldConstant41, let fInverted = fieldInverted
        else {
            fputs("[DockSwipe] ERROR: CGEventField unavailable on this macOS version\n", stderr)
            return
        }

        guard let e30 = CGEvent(source: nil) else { return }

        e30.setIntegerValueField(fEventType, value: kEventTypeMagnify)
        e30.setDoubleValueField(fSubtype, value: Double(kDockSwipeSubtype))
        e30.setDoubleValueField(fPhase, value: Double(phase))
        e30.setDoubleValueField(fPhaseDup, value: Double(phase))
        e30.setDoubleValueField(fOriginOffset, value: originOffset)
        e30.setDoubleValueField(fConstant41, value: kMagicConstant)
        e30.setDoubleValueField(fDockSwipeType, value: Double(type))
        e30.setDoubleValueField(fDockSwipeTypeDup, value: Double(type))
        e30.setDoubleValueField(fWeirdType, value: weirdHorizontalTypeValue)
        e30.setDoubleValueField(fWeirdTypeDup, value: weirdHorizontalTypeValue)

        var ofsFloat32 = Float32(originOffset)
        var ofsInt32: UInt32 = 0
        memcpy(&ofsInt32, &ofsFloat32, 4)
        e30.setIntegerValueField(fEncodedOffset, value: Int64(ofsInt32))
        e30.setIntegerValueField(fInverted, value: 1)

        if phase == kPhaseEnded, let fSpeed1 = fieldExitSpeed1, let fSpeed2 = fieldExitSpeed2 {
            let exitSpeed = originOffset * 100.0
            e30.setDoubleValueField(fSpeed1, value: exitSpeed)
            e30.setDoubleValueField(fSpeed2, value: exitSpeed)
        }

        guard let e29 = CGEvent(source: nil) else { return }
        e29.setIntegerValueField(fEventType, value: kEventTypeGesture)
        e29.setDoubleValueField(fConstant41, value: kMagicConstant)

        e30.post(tap: .cgSessionEventTap)
        e29.post(tap: .cgSessionEventTap)
    }

    /// macOS 27+ encoding. Same phases/offsets as the legacy path, carried in an
    /// IOHIDEvent payload; no type-29 companion event (unused on macOS 27).
    private static func postDockSwipeEventHID(phase: Int64, originOffset: Double, type: Int64) {
        // The legacy path always flagged invertedFromDevice (field 136 = 1). The payload has
        // no such flag — the system applies the direction itself — so progress AND exit
        // velocity are negated together: this keeps the legacy on-screen direction, and
        // negating only progress makes the release velocity point backwards (end-of-swipe
        // rebound). Mirrors MMF f92d2d53a + PR #1936/#2077 for invertedFromDevice = true.
        let progress = -originOffset
        let velocity = (phase == kPhaseEnded) ? -(originOffset * 100.0) : 0.0

        guard let event = KMCCreateDockSwipeHIDEvent(UInt32(type), UInt16(phase), progress, velocity) else {
            // Fail closed: the legacy fields are known to do nothing on macOS 27.
            if !didLogHIDFailure {
                didLogHIDFailure = true
                fputs("[DockSwipe] ERROR: macOS 27 payload unavailable (\(diagnosticDescription))\n", stderr)
            }
            return
        }
        event.post(tap: .cgSessionEventTap)
    }
}
