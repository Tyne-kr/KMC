import Cocoa
import IOKit.hidsystem

/// Manages Accessibility and Input Monitoring permissions.
/// NEVER triggers system dialogs on its own — only when user explicitly clicks a button.
final class PermissionsManager: ObservableObject {

    static let shared = PermissionsManager()

    @Published var accessibilityEnabled: Bool = false
    @Published var inputMonitoringEnabled: Bool = false

    var hasAllPermissions: Bool {
        accessibilityEnabled && inputMonitoringEnabled
    }

    private var pollTimer: Timer?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    private var hasRequestedInputMonitoring: Bool {
        get { UserDefaults.standard.bool(forKey: "HasRequestedInputMonitoring") }
        set { UserDefaults.standard.set(newValue, forKey: "HasRequestedInputMonitoring") }
    }

    private init() {
        // Silent check only — NO dialogs
        checkState()
        setupClickMonitors()
    }

    // MARK: - Silent Permission Check (prompt: NO)

    /// Check permissions silently. Never triggers system dialogs.
    func checkState() {
        // Accessibility: prompt=NO → silent check only
        let axState = checkAccessibility(prompt: false)
        if axState != accessibilityEnabled {
            accessibilityEnabled = axState
        }

        // Input Monitoring: silent check via IOHIDCheckAccess
        let imState = checkInputMonitoring(prompt: false)
        if imState != inputMonitoringEnabled {
            inputMonitoringEnabled = imState
        }
    }

    private func checkAccessibility(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func checkInputMonitoring(prompt: Bool) -> Bool {
        if prompt {
            // IOHIDRequestAccess blocks, run on background queue
            DispatchQueue.global(qos: .userInitiated).async {
                IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            }
            return false  // Can't know result immediately
        } else {
            return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        }
    }

    // MARK: - User-Triggered Permission Requests

    /// Called when user clicks the Accessibility permission button
    func requestAccessibility() {
        _ = checkAccessibility(prompt: true)  // prompt: YES → system dialog
        startPolling()
    }

    /// Called when user clicks the Input Monitoring permission button
    func requestInputMonitoring() {
        if !hasRequestedInputMonitoring {
            // macOS only shows IM dialog ONCE EVER per app
            _ = checkInputMonitoring(prompt: true)
            hasRequestedInputMonitoring = true
        } else {
            // Already requested before → open System Settings directly
            openInputMonitoringPreferences()
        }
        startPolling()
    }

    // MARK: - Open System Settings

    func openAccessibilityPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openInputMonitoringPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Polling (after user interaction)

    /// Poll permission state on mouse clicks (user may have just toggled in System Settings)
    private func setupClickMonitors() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            self?.checkState()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.checkState()
            return event
        }
    }

    func startPolling() {
        pollTimer?.invalidate()
        var pollCount = 0
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.333, repeats: true) { [weak self] timer in
            self?.checkState()
            pollCount += 1
            if pollCount >= 8 || self?.hasAllPermissions == true {
                timer.invalidate()
            }
        }
    }

    deinit {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m) }
        if let m = localClickMonitor { NSEvent.removeMonitor(m) }
        pollTimer?.invalidate()
    }
}
