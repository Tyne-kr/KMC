import Cocoa
import IOKit.hid

/// Logs all mouse events including raw HID events from firmware-level buttons.
/// Uses both CGEventTap (standard events) and IOHIDManager (raw HID reports).
final class EventLogger: ObservableObject {

    static let shared = EventLogger()

    struct EventEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let type: String
        let buttonNumber: Int64?
        let details: String
        let source: String  // "CGEvent" or "HID"
    }

    @Published var entries: [EventEntry] = []
    @Published var isLogging: Bool = false

    // CGEventTap
    fileprivate var eventTap: CFMachPort?
    private var tapRunLoopSource: CFRunLoopSource?

    // IOHIDManager for raw HID
    private var hidManager: IOHIDManager?

    private let maxEntries = 200

    private init() {}

    func startLogging() {
        guard !isLogging else { return }
        startCGEventTap()
        startHIDMonitoring()
        isLogging = true
    }

    func stopLogging() {
        stopCGEventTap()
        stopHIDMonitoring()
        isLogging = false
    }

    func clearLog() {
        entries.removeAll()
    }

    // MARK: - CGEventTap (standard mouse events)

    private func startCGEventTap() {
        guard eventTap == nil else { return }

        let eventMask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: loggerCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = eventTap else {
            addUIEntry(type: "Error", details: "CGEventTap 생성 실패 — 접근성 권한을 확인하세요", source: "System")
            return
        }

        tapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), tapRunLoopSource, .commonModes)
    }

    private func stopCGEventTap() {
        if let source = tapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            tapRunLoopSource = nil
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    // MARK: - IOHIDManager (raw HID button events)

    private func startHIDMonitoring() {
        guard hidManager == nil else { return }

        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = hidManager else { return }

        // Match mouse/gamepad/pointer devices
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
            addUIEntry(type: "Error", details: "HID Manager 열기 실패 (code: \(openResult))", source: "HID")
            return
        }

        // Register for input value changes (button presses, etc.)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, hidInputCallback, context)

        // Log connected devices
        if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in devices {
                let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
                let vendorId = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
                let productId = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
                addUIEntry(
                    type: "Device Found",
                    details: "\(name) (VID:0x\(String(vendorId, radix: 16)) PID:0x\(String(productId, radix: 16)))",
                    source: "HID"
                )
            }
        }
    }

    private func stopHIDMonitoring() {
        if let manager = hidManager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            hidManager = nil
        }
    }

    // MARK: - HID Input Callback

    func handleHIDInput(value: IOHIDValue, device: IOHIDDevice) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        let deviceName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"

        // Button page (0x09 = kHIDPage_Button)
        if usagePage == kHIDPage_Button {
            let buttonNum = usage  // Button number (1-based in HID)
            let state = intValue == 1 ? "Down" : "Up"
            addUIEntry(
                type: "HID Button \(buttonNum) \(state)",
                buttonNumber: Int64(buttonNum),
                details: "[\(deviceName)] page=0x09 usage=\(buttonNum)",
                source: "HID"
            )
            return
        }

        // Consumer page (0x0C) - some mice send DPI as consumer control
        if usagePage == kHIDPage_Consumer {
            addUIEntry(
                type: "HID Consumer",
                buttonNumber: Int64(usage),
                details: "[\(deviceName)] page=0x0C usage=0x\(String(usage, radix: 16)) val=\(intValue)",
                source: "HID"
            )
            return
        }

        // Generic Desktop page - DPI buttons sometimes appear here
        if usagePage == kHIDPage_GenericDesktop {
            // Filter out constant mouse movement (X, Y, Wheel)
            if usage == kHIDUsage_GD_X || usage == kHIDUsage_GD_Y || usage == kHIDUsage_GD_Wheel {
                return  // Skip movement/scroll data
            }
            addUIEntry(
                type: "HID Generic",
                buttonNumber: Int64(usage),
                details: "[\(deviceName)] page=0x01 usage=0x\(String(usage, radix: 16)) val=\(intValue)",
                source: "HID"
            )
            return
        }

        // Vendor-defined page (Logitech uses these for special buttons)
        if usagePage >= 0xFF00 {
            addUIEntry(
                type: "HID Vendor",
                buttonNumber: Int64(usage),
                details: "[\(deviceName)] page=0x\(String(usagePage, radix: 16)) usage=0x\(String(usage, radix: 16)) val=\(intValue)",
                source: "HID"
            )
            return
        }
    }

    // MARK: - CGEvent processing

    func addCGEventEntry(type: CGEventType, event: CGEvent) {
        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        let typeName: String
        var details = ""

        switch type {
        case .leftMouseDown:    typeName = "Left Down"
        case .leftMouseUp:      typeName = "Left Up"
        case .rightMouseDown:   typeName = "Right Down"
        case .rightMouseUp:     typeName = "Right Up"
        case .otherMouseDown:   typeName = "Button \(buttonNumber) Down"
        case .otherMouseUp:     typeName = "Button \(buttonNumber) Up"
        case .scrollWheel:
            typeName = "Scroll"
            let dy = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let dx = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
            details = "dx=\(dx) dy=\(dy) continuous=\(continuous)"
        default:
            typeName = "Type(\(type.rawValue))"
        }

        addUIEntry(
            type: typeName,
            buttonNumber: (type != .scrollWheel) ? buttonNumber : nil,
            details: details,
            source: "CGEvent"
        )
    }

    // MARK: - UI Update

    private func addUIEntry(type: String, buttonNumber: Int64? = nil, details: String = "", source: String) {
        let entry = EventEntry(
            timestamp: Date(),
            type: type,
            buttonNumber: buttonNumber,
            details: details,
            source: source
        )

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.entries.insert(entry, at: 0)
            if self.entries.count > self.maxEntries {
                self.entries.removeLast()
            }
        }
    }
}

// MARK: - C Callbacks

private func loggerCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let logger = Unmanaged<EventLogger>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = logger.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    logger.addCGEventEntry(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

private func hidInputCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard let context = context else { return }
    let logger = Unmanaged<EventLogger>.fromOpaque(context).takeUnretainedValue()

    let element = IOHIDValueGetElement(value)
    let device = IOHIDElementGetDevice(element)

    logger.handleHIDInput(value: value, device: device)
}
