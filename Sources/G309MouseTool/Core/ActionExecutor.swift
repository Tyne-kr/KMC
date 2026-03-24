import Cocoa

/// Executes macOS actions in response to mouse gestures.
/// Uses synthetic DockSwipe events (reverse-engineered from macOS internals)
/// to trigger native Space switching with the same animation as a three-finger trackpad swipe.
///
/// Reference: Mac Mouse Fix (noah-nuebling/mac-mouse-fix) TouchSimulator.m
enum ActionExecutor {

    // MARK: - Pre-computed CGEventField constants (undocumented fields)

    private static let fieldEventType       = CGEventField(rawValue: 55)!   // Event type override
    private static let fieldSubtype         = CGEventField(rawValue: 110)!  // IOHIDEvent subtype
    private static let fieldPhase           = CGEventField(rawValue: 132)!  // Phase
    private static let fieldPhaseDup        = CGEventField(rawValue: 134)!  // Phase duplicate
    private static let fieldOriginOffset    = CGEventField(rawValue: 124)!  // Cumulative offset
    private static let fieldEncodedOffset   = CGEventField(rawValue: 135)!  // Float32-as-Int64 offset
    private static let fieldDockSwipeType   = CGEventField(rawValue: 123)!  // 1=H, 2=V, 3=pinch
    private static let fieldDockSwipeTypeDup = CGEventField(rawValue: 165)! // Type duplicate
    private static let fieldWeirdType       = CGEventField(rawValue: 119)!  // Encoded type float
    private static let fieldWeirdTypeDup    = CGEventField(rawValue: 139)!  // Encoded type dup
    private static let fieldConstant41      = CGEventField(rawValue: 41)!   // Magic constant
    private static let fieldInverted        = CGEventField(rawValue: 136)!  // invertedFromDevice
    private static let fieldExitSpeed1      = CGEventField(rawValue: 129)!  // Exit speed
    private static let fieldExitSpeed2      = CGEventField(rawValue: 130)!  // Exit speed dup

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

    // MARK: - Public API

    static func executeSpaceSwitch(direction: GestureAction) {
        let sign: Double = (direction == .swipeRight) ? -1.0 : 1.0

        fputs("[ActionExecutor] executeSpaceSwitch: \(direction) sign=\(sign)\n", stderr)

        DispatchQueue.global(qos: .userInteractive).async {
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

            // Stuck-bug workaround (Mac Mouse Fix): re-send end events
            usleep(200_000)
            postDockSwipeEvent(phase: kPhaseEnded, originOffset: finalOffset, type: kDockSwipeHorizontal)
            usleep(300_000)
            postDockSwipeEvent(phase: kPhaseEnded, originOffset: finalOffset, type: kDockSwipeHorizontal)

            fputs("[ActionExecutor] DockSwipe completed: \(direction == .swipeRight ? "→" : "←")\n", stderr)
        }
    }

    // MARK: - DockSwipe Event Posting

    private static func postDockSwipeEvent(phase: Int64, originOffset: Double, type: Int64) {
        guard let e30 = CGEvent(source: nil) else { return }

        e30.setIntegerValueField(fieldEventType, value: kEventTypeMagnify)
        e30.setDoubleValueField(fieldSubtype, value: Double(kDockSwipeSubtype))
        e30.setDoubleValueField(fieldPhase, value: Double(phase))
        e30.setDoubleValueField(fieldPhaseDup, value: Double(phase))
        e30.setDoubleValueField(fieldOriginOffset, value: originOffset)
        e30.setDoubleValueField(fieldConstant41, value: kMagicConstant)
        e30.setDoubleValueField(fieldDockSwipeType, value: Double(type))
        e30.setDoubleValueField(fieldDockSwipeTypeDup, value: Double(type))
        e30.setDoubleValueField(fieldWeirdType, value: weirdHorizontalTypeValue)
        e30.setDoubleValueField(fieldWeirdTypeDup, value: weirdHorizontalTypeValue)

        var ofsFloat32 = Float32(originOffset)
        var ofsInt32: UInt32 = 0
        memcpy(&ofsInt32, &ofsFloat32, 4)
        e30.setIntegerValueField(fieldEncodedOffset, value: Int64(ofsInt32))
        e30.setIntegerValueField(fieldInverted, value: 1)

        if phase == kPhaseEnded {
            let exitSpeed = originOffset * 100.0
            e30.setDoubleValueField(fieldExitSpeed1, value: exitSpeed)
            e30.setDoubleValueField(fieldExitSpeed2, value: exitSpeed)
        }

        guard let e29 = CGEvent(source: nil) else { return }
        e29.setIntegerValueField(fieldEventType, value: kEventTypeGesture)
        e29.setDoubleValueField(fieldConstant41, value: kMagicConstant)

        fputs("[DockSwipe] phase=\(phase) offset=\(String(format: "%.2f", originOffset))\n", stderr)
        e30.post(tap: .cgSessionEventTap)
        e29.post(tap: .cgSessionEventTap)
    }
}
