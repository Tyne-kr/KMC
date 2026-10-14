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

    /// Runtime-only auto-off marker — see ScrollReverser.isAutoReverting.
    private var isAutoReverting = false

    @Published var useStandardFnKeys: Bool = false {
        didSet {
            if isAutoReverting {
                isAutoReverting = false
                stopIntercepting()
                stopDeviceMonitoring()
                return  // saved preference untouched
            }
            UserDefaults.standard.set(useStandardFnKeys, forKey: "FnKey.useStandard")
            if useStandardFnKeys {
                startIntercepting()
                startDeviceMonitoring()
                // Tap OR HID monitor failed (Accessibility / Input Monitoring
                // missing) — revert so the UI doesn't show ON with a dead
                // pipeline. Both must be alive: without the HID monitor the
                // correlation gate never passes and the feature is silently dead.
                if eventTap == nil || hidManager == nil {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.useStandardFnKeys,
                              self.eventTap == nil || self.hidManager == nil else { return }
                        self.isAutoReverting = true
                        self.useStandardFnKeys = false
                    }
                }
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

    // Source tracking: set by IOHIDManager callback, read by CGEventTap callback.
    // Both callbacks run on the main run loop (commonModes) — no locking needed.
    fileprivate var lastMediaSourceIsExternal: Bool = false
    fileprivate var lastMediaSourceTime: UInt64 = 0

    // Media keys we converted on key-down. Their repeats and key-up must be
    // converted too, regardless of the 50ms correlation window — otherwise a
    // press held longer than 50ms leaves a synthetic F-key stuck down forever.
    // Known limitation (single-user tool): keyed by media keycode only, no
    // device identity — pressing the SAME media key on two keyboards
    // simultaneously is not supported.
    fileprivate var activeConvertedKeys = Set<Int>()

    /// Post synthetic key-ups for any still-held converted keys, then clear.
    /// Called whenever held state must be dropped (stop, tap stall) so a
    /// mid-hold interruption can't leave a synthetic F-key logically stuck
    /// down at the HID level.
    fileprivate func flushHeldConvertedKeys() {
        guard !activeConvertedKeys.isEmpty else { return }
        for code in activeConvertedKeys {
            guard let fKey = FnKeyManager.mediaKeyToFKey[code] else { continue }
            if let src = CGEventSource(stateID: .hidSystemState),
               let evt = CGEvent(keyboardEventSource: src, virtualKey: fKey, keyDown: false) {
                evt.post(tap: .cghidEventTap)
            }
        }
        activeConvertedKeys.removeAll()
        fputs("[FnKey] Flushed held converted keys (synthetic key-ups posted)\n", stderr)
    }

    // Serial queue for system-state shell commands (defaults write) so rapid
    // toggles cannot land out of order.
    private let systemStateQueue = DispatchQueue(label: "com.jc.kmc.fnstate", qos: .userInitiated)

    // Timing: mach_absolute_time → nanoseconds
    fileprivate static let timebaseInfo: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    // 50ms correlation window (in nanoseconds)
    fileprivate static let correlationWindowNs: UInt64 = 50_000_000

    // NX_KEYTYPE_* values from IOKit ev_keymap.h. Keyboards vary in which
    // code they send for the track keys (NEXT/PREVIOUS vs FAST/REWIND),
    // so both variants are mapped to the same F-keys.
    static let mediaKeyToFKey: [Int: CGKeyCode] = [
        3:  122,  // NX_KEYTYPE_BRIGHTNESS_DOWN → F1
        2:  120,  // NX_KEYTYPE_BRIGHTNESS_UP   → F2
        22: 96,   // NX_KEYTYPE_ILLUMINATION_DOWN → F5
        21: 97,   // NX_KEYTYPE_ILLUMINATION_UP   → F6
        20: 98,   // NX_KEYTYPE_REWIND          → F7
        18: 98,   // NX_KEYTYPE_PREVIOUS        → F7
        16: 100,  // NX_KEYTYPE_PLAY            → F8
        17: 101,  // NX_KEYTYPE_NEXT            → F9
        19: 101,  // NX_KEYTYPE_FAST            → F9
        7:  109,  // NX_KEYTYPE_MUTE            → F10
        1:  103,  // NX_KEYTYPE_SOUND_DOWN      → F11
        0:  111,  // NX_KEYTYPE_SOUND_UP        → F12
    ]

    private init() {
        DispatchQueue.main.async { [self] in
            // isLoading stays true through this read-back so internalFnState's
            // didSet doesn't write the just-read value straight back to the
            // system (previously isLoading was cleared too early, defeating
            // the guard and re-writing fnState on every launch).
            internalFnState = readSystemFnState()
            isLoading = false
            if UserDefaults.standard.bool(forKey: "FnKey.useStandard") {
                useStandardFnKeys = true
                fputs("[FnKey] Restored: external=ON (deferred)\n", stderr)
            }
        }
    }

    /// Full restart for wake-from-sleep — recreates the tap and HID monitor
    /// instead of merely re-enabling a possibly-dead tap.
    func restart() {
        guard useStandardFnKeys else { return }
        stopIntercepting()
        stopDeviceMonitoring()
        startIntercepting()
        startDeviceMonitoring()
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

            // Down-only correlation tracking: key-ups must NOT refresh the
            // window (an external release would open a 50ms misconversion
            // window for the internal keyboard). Key-up/repeat continuity of
            // converted keys is handled by activeConvertedKeys on the tap side.
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
            fputs("[FnKey:HID] page=\(usagePage) usage=\(usage) val=\(intValue) vid=0x\(String(vid, radix:16)) transport=\(transport) internal=\(isInternal)\n", stderr)
            #endif
        }, selfPtr)

        // commonModes (not defaultMode): the CGEventTap runs in commonModes, so
        // the HID monitor must too — otherwise the 50ms correlation breaks
        // whenever a menu or modal tracking loop is active.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult != kIOReturnSuccess {
            fputs("[FnKey] IOHIDManagerOpen failed (\(openResult)) — Input Monitoring 권한 확인 필요\n", stderr)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            hidManager = nil
            return
        }
        fputs("[FnKey] Device monitoring started\n", stderr)
    }

    private func stopDeviceMonitoring() {
        guard let manager = hidManager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
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
        flushHeldConvertedKeys()
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
        systemStateQueue.async {
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
        // Key-ups may have been missed while the tap was disabled — release
        // any held synthetic F-keys and clear held-conversion state so a
        // stale entry can't misconvert the next (possibly internal-keyboard)
        // press of the same media key.
        manager.flushHeldConvertedKeys()
        return Unmanaged.passUnretained(event)
    }

    guard type.rawValue == 14 else { return Unmanaged.passUnretained(event) }
    guard let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }

    let data1 = nsEvent.data1
    let mediaKeyCode = (data1 & 0xFFFF0000) >> 16
    let keyFlags = (data1 & 0x0000FF00) >> 8
    let isKeyDown = (keyFlags & 0x01) == 0

    guard let fKeyCode = FnKeyManager.mediaKeyToFKey[mediaKeyCode] else {
        return Unmanaged.passUnretained(event)
    }

    // Held-key continuity: once a key-down is converted, its repeats and its
    // key-up are converted unconditionally — the 50ms correlation window only
    // gates NEW key-downs. Without this, a press held longer than 50ms mixed
    // F-key and media-key behavior and the synthetic F-key never received its
    // key-up (typical presses are 80-150ms, so this hit nearly every press).
    let isHeldConversion = manager.activeConvertedKeys.contains(mediaKeyCode)

    if !isHeldConversion {
        // === Source check: only intercept a NEW key-down correlated (within
        // 50ms) with an external-device HID event. Everything else passes
        // through (internal keyboard, uncorrelated, or stray key-up). ===
        let now = mach_absolute_time()
        let elapsed = now - manager.lastMediaSourceTime
        let info = FnKeyManager.timebaseInfo
        let elapsedNs = elapsed * UInt64(info.numer) / UInt64(info.denom)

        if !isKeyDown
            || elapsedNs > FnKeyManager.correlationWindowNs
            || !manager.lastMediaSourceIsExternal {
            return Unmanaged.passUnretained(event)
        }
    }

    if isKeyDown {
        manager.activeConvertedKeys.insert(mediaKeyCode)
    } else {
        manager.activeConvertedKeys.remove(mediaKeyCode)
    }

    let fKey = fKeyCode
    let down = isKeyDown
    let flags = event.flags  // preserve modifiers (Cmd+F12 etc.)
    DispatchQueue.main.async {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let evt = CGEvent(keyboardEventSource: src, virtualKey: fKey, keyDown: down) else { return }
        evt.flags = flags
        evt.post(tap: .cghidEventTap)
    }

    return nil  // suppress original media key from external keyboard
}
