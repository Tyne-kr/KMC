import Cocoa
import SwiftUI

// MARK: - Pure AppKit entry point (no SwiftUI App protocol)

@main
enum AppEntry {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.finishLaunching()
        app.run()
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    // Lazy — do NOT initialize before NSApplication is ready
    private var scrollReverser: ScrollReverser { ScrollReverser.shared }
    private var buttonRemapper: ButtonRemapper { ButtonRemapper.shared }
    private var permissions: PermissionsManager { PermissionsManager.shared }
    private var capsLock: CapsLockManager { CapsLockManager.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        fputs("[KMC] didFinishLaunching\n", stderr)

        // Hide Dock icon (LSUIElement backup)
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        registerForSleepWake()

        // Silent permission check — NO dialogs
        permissions.checkState()

        // If permissions are missing, features stay disabled
        if !permissions.hasAllPermissions {
            scrollReverser.isEnabled = false
            buttonRemapper.isEnabled = false
        }

        // Apply CapsLock delay removal if enabled
        capsLock.reapplyIfNeeded()

        fputs("[KMC] Launched. AX=\(permissions.accessibilityEnabled) IM=\(permissions.inputMonitoringEnabled)\n", stderr)
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else {
            fputs("[KMC] ERROR: no status item button\n", stderr)
            return
        }

        // Use a known-good SF Symbol, with text fallback
        if let img = NSImage(systemSymbolName: "computermouse.fill", accessibilityDescription: "KMC") {
            img.isTemplate = true
            button.image = img
        } else if let img = NSImage(systemSymbolName: "cursorarrow.click", accessibilityDescription: "KMC") {
            img.isTemplate = true
            button.image = img
        } else {
            // Ultimate fallback: text
            button.title = "KMC"
        }

        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self

        fputs("[KMC] Status item created\n", stderr)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            scrollReverser.isEnabled.toggle()
            updateStatusIcon()
        } else {
            showStatusMenu()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()

        let scrollItem = NSMenuItem(
            title: "스크롤 반전",
            action: #selector(toggleScrollReverser),
            keyEquivalent: ""
        )
        scrollItem.state = scrollReverser.isEnabled ? .on : .off
        scrollItem.target = self
        menu.addItem(scrollItem)

        let remapItem = NSMenuItem(
            title: "버튼 제스처",
            action: #selector(toggleButtonRemapper),
            keyEquivalent: ""
        )
        remapItem.state = buttonRemapper.isEnabled ? .on : .off
        remapItem.target = self
        menu.addItem(remapItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: "설정...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "종료",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleScrollReverser() {
        if !scrollReverser.isEnabled && !permissions.hasAllPermissions {
            openSettings()
            return
        }
        scrollReverser.isEnabled.toggle()
        updateStatusIcon()
    }

    @objc private func toggleButtonRemapper() {
        if !buttonRemapper.isEnabled && !permissions.hasAllPermissions {
            openSettings()
            return
        }
        buttonRemapper.isEnabled.toggle()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let contentView = SettingsView()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "KMC 설정"
            window.contentView = NSHostingView(rootView: contentView)
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func updateStatusIcon() {
        statusItem.button?.appearsDisabled = !scrollReverser.isEnabled && !buttonRemapper.isEnabled
    }

    // MARK: - Sleep/Wake

    private func registerForSleepWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func handleWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            if self.scrollReverser.isEnabled {
                self.scrollReverser.stopTaps()
                self.scrollReverser.startTaps()
            }
            if self.buttonRemapper.isEnabled {
                let wasEnabled = self.buttonRemapper.isEnabled
                self.buttonRemapper.isEnabled = false
                self.buttonRemapper.isEnabled = wasEnabled
            }
            self.capsLock.reapplyIfNeeded()
        }
    }
}
