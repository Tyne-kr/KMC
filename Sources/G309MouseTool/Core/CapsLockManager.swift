import Foundation

/// Manages Caps Lock → F18 remapping + automatic input source shortcut assignment.
///
/// Two things happen when enabled:
/// 1. `hidutil`: Caps Lock → F18 at HID driver level (bypasses all macOS Caps Lock special handling)
/// 2. `defaults write`: F18 is set as "다음 입력 소스 선택" shortcut (no manual setup needed)
///
/// Both reset on reboot → re-applied on every app launch via `reapplyIfNeeded()`.
final class CapsLockManager: ObservableObject {

    static let shared = CapsLockManager()

    // HID usage codes (Apple TN2450)
    private static let capsLockSrc = "0x700000039"
    private static let f18Dst      = "0x70000006D"

    // macOS symbolic hotkey ID for "Select next input source"
    // F18 virtual keycode = 79, no modifiers = 0, non-printable = 65535
    private static let hotkey61F18 = """
    <dict>\
    <key>enabled</key><true/>\
    <key>value</key><dict>\
    <key>parameters</key><array>\
    <integer>65535</integer>\
    <integer>79</integer>\
    <integer>0</integer>\
    </array>\
    <key>type</key><string>standard</string>\
    </dict>\
    </dict>
    """

    @Published var isEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "CapsLock.remapF18")
            if isEnabled {
                enable()
            } else {
                disable()
            }
        }
    }

    private init() {
        let saved = UserDefaults.standard.bool(forKey: "CapsLock.remapF18")
        if saved {
            isEnabled = true
        }
    }

    /// Re-apply on launch and wake from sleep
    func reapplyIfNeeded() {
        if isEnabled {
            enable()
        }
    }

    // MARK: - Enable / Disable

    private func enable() {
        // 1. Remap Caps Lock → F18 at HID level + remove delay
        let json = """
        {"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":\(Self.capsLockSrc),"HIDKeyboardModifierMappingDst":\(Self.f18Dst)}],"CapsLockDelayOverride":0}
        """
        runHidutil(json: json)

        // 2. Set F18 as "다음 입력 소스 선택" shortcut
        setInputSourceShortcutToF18()

        fputs("[CapsLock] Enabled: Caps Lock → F18 + shortcut assigned\n", stderr)
    }

    private func disable() {
        // Restore Caps Lock and default delay
        runHidutil(json: #"{"UserKeyMapping":[],"CapsLockDelayOverride":500000}"#)
        fputs("[CapsLock] Disabled: restored defaults\n", stderr)
    }

    // MARK: - Shortcut Assignment

    /// Set symbolic hotkey 61 (Select next input source) to F18
    private func setInputSourceShortcutToF18() {
        // Write the shortcut to com.apple.symbolichotkeys
        let writeProcess = Process()
        writeProcess.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        writeProcess.arguments = [
            "write", "com.apple.symbolichotkeys",
            "AppleSymbolicHotKeys", "-dict-add", "61",
            Self.hotkey61F18
        ]
        writeProcess.standardOutput = FileHandle.nullDevice
        writeProcess.standardError = FileHandle.nullDevice

        do {
            try writeProcess.run()
            writeProcess.waitUntilExit()
        } catch {
            fputs("[CapsLock] defaults write error: \(error)\n", stderr)
            return
        }

        // Activate the new settings without logout
        activateSettings()
    }

    /// Tell macOS to reload keyboard shortcut settings
    private func activateSettings() {
        let activatePath = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
        let fm = FileManager.default

        if fm.fileExists(atPath: activatePath) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: activatePath)
            process.arguments = ["-u"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                fputs("[CapsLock] activateSettings error: \(error)\n", stderr)
            }
        }
    }

    // MARK: - hidutil

    private func runHidutil(json: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", json]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            fputs("[CapsLock] hidutil error: \(error)\n", stderr)
        }
    }
}
