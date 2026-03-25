import Cocoa
import CSPI

// MARK: - Enums (matching original MouseTap.h)

enum ScrollEventSource {
    case mouse
    case trackpad
}

enum ScrollPhase {
    case normal
    case start
    case momentum
    case end
}

// MARK: - Scroll Reverser

/// Core scroll reversal engine — faithful port of Scroll Reverser (pilotmoon) MouseTap.m
/// Uses dual CGEventTap architecture with a SINGLE callback (matching original).
final class ScrollReverser: ObservableObject {

    static let shared = ScrollReverser()

    // MARK: - Published State

    @Published var isEnabled: Bool = false {
        didSet {
            if isEnabled { start() } else { stop() }
            UserDefaults.standard.set(isEnabled, forKey: "ScrollReverser.enabled")
        }
    }

    // MARK: - Settings

    @Published var reverseMouseVertical: Bool = true {
        didSet { guard !isLoading else { return }; UserDefaults.standard.set(reverseMouseVertical, forKey: "ScrollReverser.reverseMouseVertical") }
    }
    @Published var reverseMouseHorizontal: Bool = false {
        didSet { guard !isLoading else { return }; UserDefaults.standard.set(reverseMouseHorizontal, forKey: "ScrollReverser.reverseMouseHorizontal") }
    }
    @Published var reverseTrackpadVertical: Bool = false {
        didSet { guard !isLoading else { return }; UserDefaults.standard.set(reverseTrackpadVertical, forKey: "ScrollReverser.reverseTrackpadVertical") }
    }
    @Published var reverseTrackpadHorizontal: Bool = false {
        didSet { guard !isLoading else { return }; UserDefaults.standard.set(reverseTrackpadHorizontal, forKey: "ScrollReverser.reverseTrackpadHorizontal") }
    }
    @Published var discreteScrollStep: Int32 = 3 {
        didSet { guard !isLoading else { return }; UserDefaults.standard.set(discreteScrollStep, forKey: "ScrollReverser.discreteScrollStep") }
    }

    // MARK: - Tap State

    private var activeTapPort: CFMachPort?
    private var passiveTapPort: CFMachPort?
    private var activeTapSource: CFRunLoopSource?
    private var passiveTapSource: CFRunLoopSource?

    // MARK: - Touch Tracking (matching original MouseTap ivars)

    /// Max finger count since last scroll event (reset to 0 after each scroll)
    fileprivate var touching: Int = 0
    /// Nanosecond timestamp of last multi-touch gesture
    fileprivate var lastTouchTime: UInt64 = 0
    /// Previous source determination (for carry-forward in ambiguous zone)
    fileprivate var lastSource: ScrollEventSource = .mouse

    // MARK: - Init

    private var isLoading = true

    private init() {
        let ud = UserDefaults.standard
        ud.register(defaults: [
            "ScrollReverser.enabled": false,
            "ScrollReverser.reverseMouseVertical": true,
            "ScrollReverser.reverseMouseHorizontal": false,
            "ScrollReverser.reverseTrackpadVertical": false,
            "ScrollReverser.reverseTrackpadHorizontal": false,
            "ScrollReverser.discreteScrollStep": 3
        ])

        reverseMouseVertical = ud.bool(forKey: "ScrollReverser.reverseMouseVertical")
        reverseMouseHorizontal = ud.bool(forKey: "ScrollReverser.reverseMouseHorizontal")
        reverseTrackpadVertical = ud.bool(forKey: "ScrollReverser.reverseTrackpadVertical")
        reverseTrackpadHorizontal = ud.bool(forKey: "ScrollReverser.reverseTrackpadHorizontal")
        let step = Int32(ud.integer(forKey: "ScrollReverser.discreteScrollStep"))
        discreteScrollStep = step == 0 ? 3 : step

        isLoading = false

        if ud.bool(forKey: "ScrollReverser.enabled") {
            isEnabled = true
        }
    }

    // MARK: - Tap Management (matching original start/stop/enableTap)

    private func start() {
        guard activeTapPort == nil else { return }

        // Clear state (matching original)
        touching = 0
        lastTouchTime = 0
        lastSource = .mouse

        // Passive tap: listens to gesture events for touch detection (trackpad)
        // MUST be kCGSessionEventTap — gesture events are generated at session level
        // Uses SAME callback as active tap (matching original architecture)
        passiveTapPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << 29), // NSEventMaskGesture
            callback: scrollReverserCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        // Active tap: modifies scroll events (requires Accessibility permission)
        activeTapPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
            callback: scrollReverserCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        if let passive = passiveTapPort, let active = activeTapPort {
            passiveTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, passive, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), passiveTapSource, .commonModes)
            activeTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, active, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), activeTapSource, .commonModes)
        } else {
            stop()
        }
    }

    func stop() {
        if let source = activeTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            activeTapSource = nil
        }
        if let port = activeTapPort {
            CFMachPortInvalidate(port)
            activeTapPort = nil
        }
        if let source = passiveTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            passiveTapSource = nil
        }
        if let port = passiveTapPort {
            CFMachPortInvalidate(port)
            passiveTapPort = nil
        }
    }

    fileprivate func enableTap() {
        if let port = activeTapPort, !CGEvent.tapIsEnabled(tap: port) {
            CGEvent.tapEnable(tap: port, enable: true)
        }
        if let port = passiveTapPort, !CGEvent.tapIsEnabled(tap: port) {
            CGEvent.tapEnable(tap: port, enable: true)
        }
    }
}

// MARK: - Nanosecond timer (matching original _nanoseconds())

private func nanoseconds() -> UInt64 {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    var time = mach_absolute_time()
    time *= UInt64(info.numer)
    time /= UInt64(info.denom)
    return time
}

// MARK: - Momentum phase (matching original _momentumPhaseForEvent)

private func momentumPhase(for event: CGEvent) -> ScrollPhase {
    guard let nsEvent = NSEvent(cgEvent: event) else { return .normal }
    // CRITICAL: The original uses NSTouchPhase* constants to switch on momentumPhase.
    // NSTouchPhaseStationary = 1<<2 = 4, which matches NSEvent.Phase.changed (rawValue 4).
    // Swift's NSEvent.Phase.stationary has rawValue 2 — NOT the same!
    // So we must use .changed (4) to match momentum continuation events.
    switch nsEvent.momentumPhase {
    case .began:      return .start      // rawValue 1: momentum began
    case .changed:    return .momentum   // rawValue 4: momentum continuing (original: NSTouchPhaseStationary=4)
    case .ended:      return .end        // rawValue 8: momentum ended
    case .cancelled:  return .end        // rawValue 16: momentum cancelled
    default:          return .normal     // rawValue 0: no momentum (gesture phase active)
    }
}

// MARK: - Single Callback (matching original _callback exactly)

private let MILLISECOND: UInt64 = 1_000_000

private func scrollReverserCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    eventRef: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(eventRef) }
    let tap = Unmanaged<ScrollReverser>.fromOpaque(userInfo).takeUnretainedValue()
    let time = nanoseconds()

    // === NSEventTypeGesture (type 29) — touch tracking ===
    if type.rawValue == 29 {
        guard let event = NSEvent(cgEvent: eventRef) else { return Unmanaged.passUnretained(eventRef) }

        // Matching original: touchesMatchingPhase:NSTouchPhaseTouching inView:nil
        let touchingCount = event.touches(matching: .touching, in: nil).count

        if touchingCount >= 2 {
            tap.lastTouchTime = time
            tap.touching = max(tap.touching, touchingCount)  // MAX, matching original
        }
        // else: totally ignore zero or one touch events (matching original)

        return Unmanaged.passUnretained(eventRef)
    }

    // === NSEventTypeScrollWheel ===
    if type == .scrollWheel {
        let ioHidEventRef = CGEventCopyIOHIDEvent(eventRef)

        // Is continuous? (trackpad/Magic Mouse scrolling is continuous)
        let continuous = eventRef.getIntegerValueField(.scrollWheelEventIsContinuous) != 0

        // READ all deltas before any writes (matching original read order)
        let axis1 = eventRef.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let axis2 = eventRef.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let point_axis1 = eventRef.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let point_axis2 = eventRef.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        let fixedpt_axis1 = eventRef.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let fixedpt_axis2 = eventRef.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        var iohid_axis1: IOHIDFloat = 0
        var iohid_axis2: IOHIDFloat = 0
        if let hid = ioHidEventRef {
            iohid_axis1 = IOHIDEventGetFloatValue(hid, UInt32(kIOHIDEventFieldScrollY))
            iohid_axis2 = IOHIDEventGetFloatValue(hid, UInt32(kIOHIDEventFieldScrollX))
        }

        // Calculate elapsed time since touch (matching original)
        let touchElapsed = time - tap.lastTouchTime

        // Get and RESET fingers touching (matching original: tap->touching=0)
        let touching = tap.touching
        tap.touching = 0

        // Get momentum phase
        let phase = momentumPhase(for: eventRef)

        // Work out the event source (matching original block exactly)
        let lastSource = tap.lastSource
        let source: ScrollEventSource = {
            if !continuous {
                return .mouse  // assume anything not-continuous is a mouse
            }
            if touching >= 2 && touchElapsed < (MILLISECOND * 222) {
                return .trackpad
            }
            if phase == .normal && touchElapsed > (MILLISECOND * 333) {
                return .mouse
            }
            // not enough information to decide. assume the same as last time.
            return tap.lastSource
        }()
        tap.lastSource = source

        // Should we reverse? (matching original invert logic)
        let shouldReverse: Bool = {
            switch source {
            case .trackpad:
                return tap.reverseTrackpadVertical || tap.reverseTrackpadHorizontal
            case .mouse:
                return tap.reverseMouseVertical || tap.reverseMouseHorizontal
            }
        }()

        guard shouldReverse else {
            if let hid = ioHidEventRef { IOHIDEventSafeRelease(hid) }
            return Unmanaged.passUnretained(eventRef)
        }

        // Calculate multipliers (matching original vmul/hmul logic)
        let stepsize = Int64(tap.discreteScrollStep)
        let discreteAdjust = stepsize > 0 && llabs(axis1) == 1 && !continuous
        let vstep: Int64 = discreteAdjust ? stepsize : 1

        let reverseV: Bool
        let reverseH: Bool
        switch source {
        case .trackpad:
            reverseV = tap.reverseTrackpadVertical
            reverseH = tap.reverseTrackpadHorizontal
        case .mouse:
            reverseV = tap.reverseMouseVertical
            reverseH = tap.reverseMouseHorizontal
        }

        let vmul: Int64 = reverseV ? -vstep : vstep
        let hmul: Int64 = reverseH ? -1 : 1

        // WRITE values (matching original order: Delta first, then FixedPt+Point+IOHID)
        // Vertical
        if discreteAdjust || vmul != 1 {
            eventRef.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: axis1 * vmul)
        }
        if !discreteAdjust && vmul != 1 {
            eventRef.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixedpt_axis1 * Double(vmul))
            eventRef.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: point_axis1 * vmul)
            if let hid = ioHidEventRef {
                IOHIDEventSetFloatValue(hid, UInt32(kIOHIDEventFieldScrollY), iohid_axis1 * IOHIDFloat(vmul))
            }
        }

        // Horizontal
        if hmul != 1 {
            eventRef.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: axis2 * hmul)
            eventRef.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixedpt_axis2 * Double(hmul))
            eventRef.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: point_axis2 * hmul)
            if let hid = ioHidEventRef {
                IOHIDEventSetFloatValue(hid, UInt32(kIOHIDEventFieldScrollX), iohid_axis2 * IOHIDFloat(hmul))
            }
        }

        if let hid = ioHidEventRef {
            IOHIDEventSafeRelease(hid)
        }

        return Unmanaged.passUnretained(eventRef)
    }

    // Other event type — re-enable tap if it was disabled
    tap.enableTap()
    return Unmanaged.passUnretained(eventRef)
}
