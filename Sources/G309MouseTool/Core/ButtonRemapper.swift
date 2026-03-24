import Cocoa
import IOKit.hid
import os

// MARK: - Gesture Action

enum GestureAction {
    case swipeLeft   // Move to left Space
    case swipeRight  // Move to right Space
}

// MARK: - Gesture State Machine

enum GestureState {
    case idle
    case triggered       // Trigger button pressed, accumulating movement
    case actionFired     // Threshold exceeded, action fired this cycle
}

// MARK: - HID Button Identifier

/// Identifies a specific button by its HID usage page + usage
struct HIDButtonID: Codable, Equatable, CustomStringConvertible {
    let usagePage: UInt32
    let usage: UInt32

    var description: String {
        "page=0x\(String(usagePage, radix: 16)) usage=0x\(String(usage, radix: 16))"
    }

    var displayName: String {
        if usagePage == UInt32(kHIDPage_Button) {
            return "Button \(usage)"
        } else if usagePage >= 0xFF00 {
            return "Vendor 0x\(String(usage, radix: 16))"
        } else {
            return "HID \(description)"
        }
    }
}

// MARK: - Button Remapper

/// Captures a designated HID button and converts hold+mouse-move into macOS Spaces gestures.
/// Uses IOHIDManager to detect vendor-specific buttons (like G309 DPI button).
/// Uses CGEventTap to track mouse movement for gesture detection.
final class ButtonRemapper: ObservableObject {

    static let shared = ButtonRemapper()

    // MARK: - Published State

    @Published var isEnabled: Bool = false {
        didSet {
            if isEnabled {
                start()
            } else {
                stop()
            }
            UserDefaults.standard.set(isEnabled, forKey: "ButtonRemapper.enabled")
        }
    }

    // MARK: - Settings

    /// The HID button to use as gesture trigger
    @Published var triggerButton: HIDButtonID? = nil {
        didSet {
            if let btn = triggerButton, let data = try? JSONEncoder().encode(btn) {
                UserDefaults.standard.set(data, forKey: "ButtonRemapper.triggerButtonHID")
            }
        }
    }

    /// Display string for current trigger
    var triggerDisplayName: String {
        triggerButton?.displayName ?? "설정 안됨"
    }

    /// Pixel threshold to trigger a space switch
    @Published var thresholdPixels: CGFloat = 150 {
        didSet { UserDefaults.standard.set(Double(thresholdPixels), forKey: "ButtonRemapper.threshold") }
    }

    /// Allow multiple switches in a single hold
    @Published var allowContinuousSwipe: Bool = false {
        didSet { UserDefaults.standard.set(allowContinuousSwipe, forKey: "ButtonRemapper.continuousSwipe") }
    }

    /// Invert swipe direction (natural vs standard)
    /// false = 마우스 이동 방향 = Space 이동 방향 (기본)
    /// true  = 마우스 이동 방향 반대 = Space 이동 방향 (자연스러운 스크롤 방식)
    @Published var invertDirection: Bool = false {
        didSet { UserDefaults.standard.set(invertDirection, forKey: "ButtonRemapper.invertDirection") }
    }

    // MARK: - Button Detection Mode

    @Published var isDetecting: Bool = false
    @Published var detectedButton: HIDButtonID? = nil

    // MARK: - Internal State (protected by stateLock)

    private var stateLock = os_unfair_lock()
    private var state: GestureState = .idle
    private var accumulatedDeltaX: CGFloat = 0
    private var triggerButtonPressed: Bool = false

    // IOHIDManager for button detection
    private var hidManager: IOHIDManager?

    // CGEventTap for mouse movement tracking
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // MARK: - Init

    private init() {
        loadSettings()
    }

    private func loadSettings() {
        let ud = UserDefaults.standard
        ud.register(defaults: [
            "ButtonRemapper.enabled": false,
            "ButtonRemapper.threshold": 150.0,
            "ButtonRemapper.continuousSwipe": false,
            "ButtonRemapper.invertDirection": false
        ])

        // Load HID button ID
        if let data = ud.data(forKey: "ButtonRemapper.triggerButtonHID"),
           let btn = try? JSONDecoder().decode(HIDButtonID.self, from: data) {
            triggerButton = btn
        }

        thresholdPixels = CGFloat(ud.double(forKey: "ButtonRemapper.threshold"))
        if thresholdPixels == 0 { thresholdPixels = 150 }
        allowContinuousSwipe = ud.bool(forKey: "ButtonRemapper.continuousSwipe")
        invertDirection = ud.bool(forKey: "ButtonRemapper.invertDirection")

        let enabled = ud.bool(forKey: "ButtonRemapper.enabled")
        if enabled {
            isEnabled = true
        }
    }

    // MARK: - Start / Stop

    private func start() {
        startHIDMonitoring()
        startMouseMovementTap()
    }

    private func stop() {
        stopHIDMonitoring()
        stopMouseMovementTap()
        os_unfair_lock_lock(&stateLock)
        state = .idle
        accumulatedDeltaX = 0
        triggerButtonPressed = false
        os_unfair_lock_unlock(&stateLock)
    }

    // MARK: - IOHIDManager (button press/release detection)

    private func startHIDMonitoring() {
        guard hidManager == nil else { return }

        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = hidManager else { return }

        // Match mouse and pointer devices
        let matchingDicts: [[String: Any]] = [
            [
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse
            ],
            [
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer
            ]
        ]

        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingDicts as CFArray)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult != kIOReturnSuccess {
            fputs("[ButtonRemapper] HID Manager open failed: \(openResult)\n", stderr)
            return
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, hidValueCallback, context)
    }

    private func stopHIDMonitoring() {
        if let manager = hidManager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            hidManager = nil
        }
    }

    // MARK: - CGEventTap (mouse movement tracking only)

    private func startMouseMovementTap() {
        guard eventTap == nil else { return }

        let eventMask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,  // Listen only — just track movement
            eventsOfInterest: eventMask,
            callback: movementCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = eventTap else {
            fputs("[ButtonRemapper] Failed to create movement tap\n", stderr)
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
    }

    private func stopMouseMovementTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    // MARK: - HID Input Processing

    func handleHIDValue(value: IOHIDValue, device: IOHIDDevice) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        // Skip mouse movement axes
        if usagePage == UInt32(kHIDPage_GenericDesktop) {
            if usage == UInt32(kHIDUsage_GD_X) || usage == UInt32(kHIDUsage_GD_Y) || usage == UInt32(kHIDUsage_GD_Wheel) {
                return
            }
        }

        // Only care about button-like events (value 0 or 1)
        guard intValue == 0 || intValue == 1 else { return }

        let buttonID = HIDButtonID(usagePage: usagePage, usage: usage)
        let isPressed = intValue == 1

        // Detection mode: capture button press (skip left/right click to prevent accidental assignment)
        if isDetecting && isPressed {
            if usagePage == UInt32(kHIDPage_Button) && (usage == 1 || usage == 2) {
                return  // Skip left click (1) and right click (2)
            }
            DispatchQueue.main.async { [weak self] in
                self?.detectedButton = buttonID
                self?.isDetecting = false
            }
            return
        }

        // Trigger button handling
        guard let trigger = triggerButton, buttonID == trigger else { return }

        os_unfair_lock_lock(&stateLock)
        if isPressed {
            triggerButtonPressed = true
            state = .triggered
            accumulatedDeltaX = 0
            fputs("[ButtonRemapper] Trigger button PRESSED\n", stderr)
        } else {
            triggerButtonPressed = false
            state = .idle
            accumulatedDeltaX = 0
            fputs("[ButtonRemapper] Trigger button RELEASED\n", stderr)
        }
        os_unfair_lock_unlock(&stateLock)
    }

    // MARK: - Mouse Movement Processing

    func handleMouseMovement(deltaX: CGFloat) {
        var actionToFire: GestureAction? = nil

        os_unfair_lock_lock(&stateLock)

        guard triggerButtonPressed && (state == .triggered || state == .actionFired) else {
            os_unfair_lock_unlock(&stateLock)
            return
        }

        accumulatedDeltaX += deltaX

        if state == .triggered && abs(accumulatedDeltaX) >= thresholdPixels {
            let movedRight = accumulatedDeltaX > 0
            // invertDirection: false = 이동 방향과 같음, true = 반대
            if invertDirection {
                actionToFire = movedRight ? .swipeLeft : .swipeRight
            } else {
                actionToFire = movedRight ? .swipeRight : .swipeLeft
            }
            state = .actionFired

            if allowContinuousSwipe {
                accumulatedDeltaX = 0
                state = .triggered
            }
        }

        os_unfair_lock_unlock(&stateLock)

        // Fire action outside the lock to avoid race window
        if let action = actionToFire {
            fputs("[ButtonRemapper] Threshold crossed! deltaX=\(accumulatedDeltaX) action=\(action)\n", stderr)
            ActionExecutor.executeSpaceSwitch(direction: action)
        }
    }
}

// MARK: - C Callbacks

private func hidValueCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard let context = context else { return }
    let remapper = Unmanaged<ButtonRemapper>.fromOpaque(context).takeUnretainedValue()

    let element = IOHIDValueGetElement(value)
    let device = IOHIDElementGetDevice(element)

    remapper.handleHIDValue(value: value, device: device)
}

private func movementCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let remapper = Unmanaged<ButtonRemapper>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = remapper.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    let deltaX = CGFloat(event.getIntegerValueField(.mouseEventDeltaX))
    remapper.handleMouseMovement(deltaX: deltaX)

    return Unmanaged.passUnretained(event)
}
