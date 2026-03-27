import Cocoa
import IOKit
import IOKit.hid

/// Intercepts media key events from external keyboards and converts them to F1-F12.
///
/// Architecture:
/// 1. IOHIDManager monitors all keyboard/consumer devices
/// 2. Each device is classified as internal or external using:
///    - kIOHIDBuiltInKey ("Built-In" property)
///    - kIOHIDTransportKey ("SPI"/"FIFO" = internal)
///    - Product name containing "Apple Internal"
/// 3. When a consumer-page (media key) or F-key event arrives via IOHIDManager,
///    we record whether it came from an internal or external device.
/// 4. CGEventTap intercepts NX_SYSDEFINED media key events.
///    If the most recent HID event was from an external device (within 50ms),
///    we suppress the media key and post a replacement F-key keyboard event.
///
/// Reference: Karabiner-Elements device_properties.hpp for internal keyboard detection.
final class FnKeyManager: ObservableObject {

    static let shared = FnKeyManager()

    @Published var useStandardFnKeys: Bool = false {
        didSet {
            UserDefaults.standard.set(useStandardFnKeys, forKey: "FnKey.useStandard")
            if useStandardFnKeys {
                startIntercepting()
                startDeviceMonitoring()
            } else {
                stopIntercepting()
                stopDeviceMonitoring()
            }
        }
    }

    @Published var internalFnState: Bool = false {
        didSet {
            guard !isLoading else { return }
            setSystemFnState(internalFnState)
        }
    }

    private var isLoading = true

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hidManager: IOHIDManager?

    // Source tracking: set by IOHIDManager callback, read by CGEventTap callback
    fileprivate var lastMediaSourceIsExternal: Bool = false
    fileprivate var lastMediaSourceTime: UInt64 = 0

    // Timing: mach_absolute_time → nanoseconds
    fileprivate static let timebaseInfo: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    // 50ms correlation window (in nanoseconds)
    fileprivate static let correlationWindowNs: UInt64 = 50_000_000

    static let mediaKeyToFKey: [Int: CGKeyCode] = [
        3:  122,  // BRIGHTNESS_DOWN → F1
        2:  120,  // BRIGHTNESS_UP   → F2
        22: 96,   // ILLUM_DOWN      → F5
        21: 97,   // ILLUM_UP        → F6
        20: 98,   // REWIND          → F7
        16: 100,  // PLAY            → F8
        17: 101,  // FAST            → F9
        7:  109,  // MUTE            → F10
        1:  103,  // SOUND_DOWN      → F11
        0:  111,  // SOUND_UP        → F12
    ]

    private init() {
        isLoading = false
        DispatchQueue.main.async { [self] in
            internalFnState = readSystemFnState()
            if UserDefaults.standard.bool(forKey: "FnKey.useStandard") {
                useStandardFnKeys = true
                fputs("[FnKey] Restored: external=ON (deferred)\n", stderr)
            }
        }
    }

    func reapplyIfNeeded() {
        if useStandardFnKeys {
            if eventTap == nil { startIntercepting() }
            else if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            if hidManager == nil { startDeviceMonitoring() }
        }
    }

    // MARK: - Internal Keyboard Detection (Karabiner-Elements approach)

    /// Determine if an IOHIDDevice is the MacBook's built-in keyboard.
    /// Uses three methods in order of reliability:
    /// 1. "Built-In" boolean property
    /// 2. Transport = "SPI" or "FIFO" (Apple Silicon internal bus)
    /// 3. Product name contains "Apple Internal"
    private static func isBuiltInDevice(_ device: IOHIDDevice) -> Bool {
        // Method 1: Built-In property
        if let builtIn = IOHIDDeviceGetProperty(device, "Built-In" as CFString) {
            if let boolVal = builtIn as? Bool, boolVal { return true }
            if let numVal = builtIn as? Int, numVal != 0 { return true }
        }

        // Method 2: Transport check
        if let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String {
            let t = transport.uppercased()
            if t == "SPI" || t == "FIFO" { return true }
        }

        // Method 3: Product name
        if let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String {
            if product.contains("Apple Internal") { return true }
        }

        return false
    }

    // MARK: - IOHIDManager (keyboard source tracking)

    private func startDeviceMonitoring() {
        guard hidManager == nil else { return }

        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = hidManager else { return }

        // Match BOTH keyboard and consumer devices
        // Consumer page catches media key events from keyboards
        let criteria: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
             kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard],
            [kIOHIDDeviceUsagePageKey as String: kHIDPage_Consumer,
             kIOHIDDeviceUsageKey as String: kHIDUsage_Csmr_ConsumerControl],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, criteria as CFArray)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context = context else { return }

            let element = IOHIDValueGetElement(value)
            let usagePage = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)

            // Track consumer page events (media keys) and keyboard F-keys
            let isConsumer = (usagePage == kHIDPage_Consumer)
            let isFKey = (usagePage == kHIDPage_KeyboardOrKeypad && usage >= 0x3A && usage <= 0x45)

            guard isConsumer || isFKey else { return }

            // Only track key-down (non-zero value)
            let intValue = IOHIDValueGetIntegerValue(value)
            guard intValue != 0 else { return }

            let device = IOHIDElementGetDevice(element)
            let isInternal = FnKeyManager.isBuiltInDevice(device)
            let fnMgr = Unmanaged<FnKeyManager>.fromOpaque(context).takeUnretainedValue()

            fnMgr.lastMediaSourceIsExternal = !isInternal
            fnMgr.lastMediaSourceTime = mach_absolute_time()

            #if DEBUG
            let vid = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
            let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "?"
            fputs("[FnKey:HID] page=\(usagePage) usage=\(usage) vid=0x\(String(vid, radix:16)) transport=\(transport) internal=\(isInternal)\n", stderr)
            #endif
        }, selfPtr)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        fputs("[FnKey] Device monitoring started\n", stderr)
    }

    private func stopDeviceMonitoring() {
        guard let manager = hidManager else { return }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        hidManager = nil
        fputs("[FnKey] Device monitoring stopped\n", stderr)
    }

    // MARK: - Event Tap

    private func startIntercepting() {
        guard eventTap == nil else { return }

        let eventMask: CGEventMask = (1 << 14)  // NX_SYSDEFINED

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: fnKeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = eventTap else {
            fputs("[FnKey] Failed to create event tap\n", stderr)
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        fputs("[FnKey] Media key interception started\n", stderr)
    }

    private func stopIntercepting() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        fputs("[FnKey] Media key interception stopped\n", stderr)
    }

    // MARK: - Internal Keyboard System Preference

    private func readSystemFnState() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        proc.arguments = ["read", "-g", "com.apple.keyboard.fnState"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return output == "1"
        } catch {
            return false
        }
    }

    private func setSystemFnState(_ standardFn: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            proc.arguments = ["write", "-g", "com.apple.keyboard.fnState", "-bool", standardFn ? "true" : "false"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                fputs("[FnKey] defaults write error: \(error)\n", stderr)
                return
            }

            let activatePath = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
            if FileManager.default.fileExists(atPath: activatePath) {
                let activate = Process()
                activate.executableURL = URL(fileURLWithPath: activatePath)
                activate.arguments = ["-u"]
                activate.standardOutput = FileHandle.nullDevice
                activate.standardError = FileHandle.nullDevice
                do { try activate.run(); activate.waitUntilExit() } catch {}
            }
            fputs("[FnKey] Internal keyboard fnState → \(standardFn)\n", stderr)
        }
    }
}

// MARK: - CGEventTap Callback

private func fnKeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<FnKeyManager>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = manager.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    guard type.rawValue == 14 else { return Unmanaged.passUnretained(event) }
    guard let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }

    // === Source check: only intercept if from external keyboard ===
    let now = mach_absolute_time()
    let elapsed = now - manager.lastMediaSourceTime
    let info = FnKeyManager.timebaseInfo
    let elapsedNs = elapsed * UInt64(info.numer) / UInt64(info.denom)

    // Within 50ms correlation window AND from external device?
    if elapsedNs > FnKeyManager.correlationWindowNs || !manager.lastMediaSourceIsExternal {
        // Either too old (no correlation) or from internal keyboard → pass through
        return Unmanaged.passUnretained(event)
    }

    let data1 = nsEvent.data1
    let mediaKeyCode = (data1 & 0xFFFF0000) >> 16
    let keyFlags = (data1 & 0x0000FF00) >> 8
    let isKeyDown = (keyFlags & 0x01) == 0

    guard let fKeyCode = FnKeyManager.mediaKeyToFKey[mediaKeyCode] else {
        return Unmanaged.passUnretained(event)
    }

    let fKey = fKeyCode
    let down = isKeyDown
    DispatchQueue.main.async {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let evt = CGEvent(keyboardEventSource: src, virtualKey: fKey, keyDown: down) else { return }
        evt.post(tap: .cghidEventTap)
    }

    return nil  // suppress original media key from external keyboard
}
