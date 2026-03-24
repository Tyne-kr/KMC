import Cocoa
import CSPI

// MARK: - Scroll Source Detection

enum ScrollSource {
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

/// Core scroll reversal engine ported from Scroll Reverser (pilotmoon)
/// Uses dual CGEventTap architecture: passive tap for gesture detection, active tap for scroll modification
final class ScrollReverser: ObservableObject {

    static let shared = ScrollReverser()

    // MARK: - Published State

    @Published var isEnabled: Bool = false {
        didSet {
            if isEnabled {
                startTaps()
            } else {
                stopTaps()
            }
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

    private var activeTap: CFMachPort?
    private var passiveTap: CFMachPort?
    private var activeRunLoopSource: CFRunLoopSource?
    private var passiveRunLoopSource: CFRunLoopSource?

    // MARK: - Touch Tracking (from passive tap)

    private var lastTouchTime: TimeInterval = 0
    private var lastTouchCount: Int = 0
    private var lastSource: ScrollSource = .mouse

    // Timing thresholds (empirically tuned, from Scroll Reverser)
    private let touchThreshold: TimeInterval = 0.222  // 222ms
    private let touchTimeout: TimeInterval = 0.333     // 333ms

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

        // Set backing storage directly — no didSet side effects
        reverseMouseVertical = ud.bool(forKey: "ScrollReverser.reverseMouseVertical")
        reverseMouseHorizontal = ud.bool(forKey: "ScrollReverser.reverseMouseHorizontal")
        reverseTrackpadVertical = ud.bool(forKey: "ScrollReverser.reverseTrackpadVertical")
        reverseTrackpadHorizontal = ud.bool(forKey: "ScrollReverser.reverseTrackpadHorizontal")
        let step = Int32(ud.integer(forKey: "ScrollReverser.discreteScrollStep"))
        discreteScrollStep = step == 0 ? 3 : step

        isLoading = false

        // Now enable with side effects
        if ud.bool(forKey: "ScrollReverser.enabled") {
            isEnabled = true
        }
    }

    // MARK: - Event Tap Management

    func startTaps() {
        guard activeTap == nil else { return }

        // Active tap: intercepts and modifies scroll wheel events
        let activeEvents: CGEventMask = (1 << CGEventType.scrollWheel.rawValue)

        activeTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: activeEvents,
            callback: scrollCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        // Passive tap: listens to gesture events for touch detection
        let gestureEventMask: CGEventMask = (1 << 29) // NSEventTypeGesture = 29

        passiveTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: gestureEventMask,
            callback: gestureCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        if let activeTap = activeTap {
            activeRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, activeTap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), activeRunLoopSource, .commonModes)
        }

        if let passiveTap = passiveTap {
            passiveRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, passiveTap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), passiveRunLoopSource, .commonModes)
        }
    }

    func stopTaps() {
        if let source = activeRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            activeRunLoopSource = nil
        }
        if let source = passiveRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            passiveRunLoopSource = nil
        }
        if let tap = activeTap {
            CFMachPortInvalidate(tap)
            activeTap = nil
        }
        if let tap = passiveTap {
            CFMachPortInvalidate(tap)
            passiveTap = nil
        }
    }

    func reEnableTaps() {
        if let tap = activeTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        if let tap = passiveTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    // MARK: - Source Detection

    func detectSource(for event: CGEvent) -> ScrollSource {
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0

        // Non-continuous scrolling is always mouse (discrete wheel)
        if !isContinuous {
            lastSource = .mouse
            return .mouse
        }

        let now = ProcessInfo.processInfo.systemUptime
        let timeSinceTouch = now - lastTouchTime

        // Recent multi-finger touch → trackpad
        if lastTouchCount >= 2 && timeSinceTouch < touchThreshold {
            lastSource = .trackpad
            return .trackpad
        }

        // Determine momentum phase
        let phase = momentumPhase(for: event)

        // Normal phase with no recent touch → mouse (e.g., Magic Mouse)
        if phase == .normal && timeSinceTouch > touchTimeout {
            lastSource = .mouse
            return .mouse
        }

        return lastSource
    }

    private func momentumPhase(for event: CGEvent) -> ScrollPhase {
        let raw = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        switch raw {
        case 1: return .start       // NSTouchPhaseBegan
        case 2: return .momentum    // NSTouchPhaseStationary (fingers lifted, momentum)
        case 4: return .end         // NSTouchPhaseEnded
        case 8: return .end         // NSTouchPhaseCancelled
        default: return .normal
        }
    }

    // MARK: - Scroll Reversal

    func processScrollEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let source = detectSource(for: event)

        let shouldReverseVertical: Bool
        let shouldReverseHorizontal: Bool

        switch source {
        case .mouse:
            shouldReverseVertical = reverseMouseVertical
            shouldReverseHorizontal = reverseMouseHorizontal
        case .trackpad:
            shouldReverseVertical = reverseTrackpadVertical
            shouldReverseHorizontal = reverseTrackpadHorizontal
        }

        guard shouldReverseVertical || shouldReverseHorizontal else {
            return Unmanaged.passUnretained(event)
        }

        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0

        // Calculate multipliers
        let vStep: Int64
        if !isContinuous {
            let axis1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            if abs(axis1) == 1 {
                vStep = Int64(discreteScrollStep)
            } else {
                vStep = 1
            }
        } else {
            vStep = 1
        }

        let vMul: Int64 = shouldReverseVertical ? -vStep : vStep
        let hMul: Int64 = shouldReverseHorizontal ? -1 : 1

        // ===== READ all values BEFORE any modification =====
        // (setting DeltaAxis causes macOS to recalculate PointDelta/FixedPtDelta)
        // Matches original MouseTap.m: all reads first, all writes after

        // Integer deltas
        let axis1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let axis2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let point_axis1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let point_axis2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)

        // FixedPt uses Double (matches original CGEventGetDoubleValueField)
        let fixedpt_axis1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let fixedpt_axis2 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)

        // IOHID float values (read before write, alongside everything else)
        let hidEvent = CGEventCopyIOHIDEvent(event)
        var iohid_axis1: IOHIDFloat = 0
        var iohid_axis2: IOHIDFloat = 0
        if let hid = hidEvent {
            iohid_axis1 = IOHIDEventGetFloatValue(hid, UInt32(kIOHIDEventFieldScrollY))
            iohid_axis2 = IOHIDEventGetFloatValue(hid, UInt32(kIOHIDEventFieldScrollX))
        }

        // ===== WRITE values back =====
        // Order: Delta first (triggers recalc), FixedPt second, Point last
        // This matches original MouseTap.m comment:
        // "point value must be set last to preserve smooth scrolling"

        if shouldReverseVertical {
            // 1. DeltaAxis (triggers internal recalculation)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: axis1 * vMul)

            if isContinuous || abs(axis1) != 1 {
                // 2. FixedPtDelta (Double)
                event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixedpt_axis1 * Double(vMul))
                // 3. PointDelta (set LAST — overrides macOS recalculation)
                event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: point_axis1 * vMul)
            }

            // 4. IOHID
            if let hid = hidEvent {
                IOHIDEventSetFloatValue(hid, UInt32(kIOHIDEventFieldScrollY), iohid_axis1 * IOHIDFloat(vMul))
            }
        }

        if shouldReverseHorizontal {
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: axis2 * hMul)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixedpt_axis2 * Double(hMul))
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: point_axis2 * hMul)

            if let hid = hidEvent {
                IOHIDEventSetFloatValue(hid, UInt32(kIOHIDEventFieldScrollX), iohid_axis2 * IOHIDFloat(hMul))
            }
        }

        // Release IOHIDEvent (CF type returned by CGEventCopyIOHIDEvent)
        if let hid = hidEvent {
            IOHIDEventSafeRelease(hid)
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Touch Tracking

    func updateTouchInfo(from event: NSEvent) {
        let touches = event.allTouches()
        let activeTouches = touches.filter { $0.phase == .touching }
        let count = activeTouches.count

        if count >= 2 {
            lastTouchCount = count
            lastTouchTime = ProcessInfo.processInfo.systemUptime
        } else if count == 0 {
            // Don't reset lastTouchTime—we use it for timeout detection
        }
    }
}

// MARK: - C Callback Functions

private func scrollCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let reverser = Unmanaged<ScrollReverser>.fromOpaque(userInfo).takeUnretainedValue()

    // Re-enable tap if it was disabled by the system
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        reverser.reEnableTaps()
        return Unmanaged.passUnretained(event)
    }

    guard type == .scrollWheel else {
        return Unmanaged.passUnretained(event)
    }

    return reverser.processScrollEvent(event)
}

private func gestureCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let reverser = Unmanaged<ScrollReverser>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        reverser.reEnableTaps()
        return Unmanaged.passUnretained(event)
    }

    // Convert CGEvent to NSEvent to access touch data
    if let nsEvent = NSEvent(cgEvent: event) {
        reverser.updateTouchInfo(from: nsEvent)
    }

    return Unmanaged.passUnretained(event)
}
