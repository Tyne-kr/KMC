import Cocoa
import IOKit
import IOKit.hid

/// Intercepts media key events (brightness, volume, play, etc.) from external keyboards
/// and converts them back to standard F1-F12 key events.
///
/// Uses CGEventTap to intercept NX_SYSDEFINED media key events, suppress the original,
/// and post a replacement keyboard event asynchronously.
///
/// Requires Accessibility permission for active CGEventTap.
final class FnKeyManager: ObservableObject {

    static let shared = FnKeyManager()

    // External keyboard: CGEventTap intercepts media keys → F1-F12
    @Published var useStandardFnKeys: Bool = false {
        didSet {
            UserDefaults.standard.set(useStandardFnKeys, forKey: "FnKey.useStandard")
            if useStandardFnKeys {
                startIntercepting()
            } else {
                stopIntercepting()
            }
        }
    }

    // Internal keyboard: macOS system preference (com.apple.keyboard.fnState)
    @Published var internalFnState: Bool = false {
        didSet {
            guard !isLoading else { return }
            setSystemFnState(internalFnState)
        }
    }

    private var isLoading = true

    // CGEventTap for intercepting media key events
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // NX media key type → macOS virtual keycode mapping
    static let mediaKeyToFKey: [Int: CGKeyCode] = [
        3:  122,  // NX_KEYTYPE_BRIGHTNESS_DOWN    → F1
        2:  120,  // NX_KEYTYPE_BRIGHTNESS_UP      → F2
        22: 96,   // NX_KEYTYPE_ILLUMINATION_DOWN  → F5
        21: 97,   // NX_KEYTYPE_ILLUMINATION_UP    → F6
        20: 98,   // NX_KEYTYPE_REWIND             → F7
        16: 100,  // NX_KEYTYPE_PLAY               → F8
        17: 101,  // NX_KEYTYPE_FAST               → F9
        7:  109,  // NX_KEYTYPE_MUTE               → F10
        1:  103,  // NX_KEYTYPE_SOUND_DOWN         → F11
        0:  111,  // NX_KEYTYPE_SOUND_UP           → F12
    ]

    private init() {
        isLoading = false
        // Defer ALL initialization to after run loop is active.
        // CGEventTap created before run loop starts won't receive events.
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
            if eventTap == nil {
                startIntercepting()
            } else if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
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
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        fputs("[FnKey] Media key interception started\n", stderr)
    }

    private func stopIntercepting() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        fputs("[FnKey] Media key interception stopped\n", stderr)
    }

    // MARK: - Internal Keyboard (System Preference)

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

// MARK: - C Callback (identical to proven standalone test script)

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

    let data1 = nsEvent.data1
    let mediaKeyCode = (data1 & 0xFFFF0000) >> 16
    let keyFlags = (data1 & 0x0000FF00) >> 8
    let isKeyDown = (keyFlags & 0x01) == 0

    guard let fKeyCode = FnKeyManager.mediaKeyToFKey[mediaKeyCode] else {
        return Unmanaged.passUnretained(event)
    }

    // Exact same approach as the proven standalone test:
    // async post with hidSystemState source to cghidEventTap
    let fKey = fKeyCode
    let down = isKeyDown
    DispatchQueue.main.async {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let evt = CGEvent(keyboardEventSource: src, virtualKey: fKey, keyDown: down) else { return }
        evt.post(tap: .cghidEventTap)
    }

    return nil  // suppress original media key
}
