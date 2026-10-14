import Cocoa
import Combine
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
    private var cancellables = Set<AnyCancellable>()

    // Lazy — do NOT initialize before NSApplication is ready
    private var scrollReverser: ScrollReverser { ScrollReverser.shared }
    private var buttonRemapper: ButtonRemapper { ButtonRemapper.shared }
    private var permissions: PermissionsManager { PermissionsManager.shared }
    private var capsLock: CapsLockManager { CapsLockManager.shared }
    private var fnKey: FnKeyManager { FnKeyManager.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        fputs("[KMC] didFinishLaunching\n", stderr)

        // Hide Dock icon (LSUIElement backup)
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        registerForSleepWake()
        registerForThemeChange()

        // Silent permission check — NO dialogs
        permissions.checkState()

        // Permissions missing at launch: each manager's start() fails and
        // auto-reverts its runtime toggle WITHOUT persisting — the user's
        // saved preferences survive and restore on the next launch after
        // permissions are granted. (Force-writing false here used to wipe them.)

        // Apply CapsLock delay removal if enabled
        capsLock.reapplyIfNeeded()

        // Observe all feature toggles to update status icon dots
        observeFeatureStates()
        updateStatusIcon()

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
            // Same permission guard as the menu path — enabling without
            // permissions would create a dead tap.
            if !scrollReverser.isEnabled && !permissions.hasAllPermissions {
                openSettings()
                return
            }
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

        let fnKeyItem = NSMenuItem(
            title: "F1~F12 표준 기능키",
            action: #selector(toggleFnKeys),
            keyEquivalent: ""
        )
        fnKeyItem.state = fnKey.useStandardFnKeys ? .on : .off
        fnKeyItem.target = self
        menu.addItem(fnKeyItem)

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
    }

    @objc private func toggleButtonRemapper() {
        if !buttonRemapper.isEnabled && !permissions.hasAllPermissions {
            openSettings()
            return
        }
        buttonRemapper.isEnabled.toggle()
    }

    @objc private func toggleFnKeys() {
        if !fnKey.useStandardFnKeys && !permissions.hasAllPermissions {
            openSettings()
            return
        }
        fnKey.useStandardFnKeys.toggle()
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

    private func observeFeatureStates() {
        // Use receive(on:) to ensure we read AFTER the value changes
        // (@Published's $ publisher fires on willSet = before the value updates)
        let q = DispatchQueue.main
        scrollReverser.$isEnabled.receive(on: q).sink { [weak self] _ in self?.updateStatusIcon() }.store(in: &cancellables)
        buttonRemapper.$isEnabled.receive(on: q).sink { [weak self] _ in self?.updateStatusIcon() }.store(in: &cancellables)
        capsLock.$isEnabled.receive(on: q).sink { [weak self] _ in self?.updateStatusIcon() }.store(in: &cancellables)
        fnKey.$useStandardFnKeys.receive(on: q).sink { [weak self] _ in self?.updateStatusIcon() }.store(in: &cancellables)
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        let states = [
            scrollReverser.isEnabled,
            buttonRemapper.isEnabled,
            capsLock.isEnabled,
            fnKey.useStandardFnKeys,
        ]

        let anyEnabled = states.contains(true)
        button.appearsDisabled = !anyEnabled

        // Detect dark/light menu bar
        let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let iconColor: NSColor = isDark ? .white : .black

        // Create composite image: mouse icon on top + 4 dots at bottom
        let totalSize = NSSize(width: 20, height: 22)
        let img = NSImage(size: totalSize, flipped: false) { rect in
            // Draw mouse icon
            if let baseIcon = NSImage(systemSymbolName: "computermouse.fill", accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                let configured = baseIcon.withSymbolConfiguration(config) ?? baseIcon
                let iconW: CGFloat = 14
                let iconH: CGFloat = 17
                let iconX = (rect.width - iconW) / 2
                let iconRect = NSRect(x: iconX, y: 4, width: iconW, height: iconH)

                // Tint the icon by drawing it with compositing
                iconColor.setFill()
                iconRect.fill(using: .sourceOver)
                configured.draw(in: iconRect, from: .zero, operation: .destinationIn, fraction: 1.0)
            }

            // Draw 4 indicator dots at the bottom
            let dotSize: CGFloat = 2.5
            let dotSpacing: CGFloat = 1.5
            let totalWidth = 4 * dotSize + 3 * dotSpacing
            let startX = (rect.width - totalWidth) / 2

            for (i, enabled) in states.enumerated() {
                let x = startX + CGFloat(i) * (dotSize + dotSpacing)
                let dotRect = NSRect(x: x, y: 0.5, width: dotSize, height: dotSize)
                let color: NSColor = enabled ? .systemGreen : (isDark ? NSColor.white.withAlphaComponent(0.25) : NSColor.black.withAlphaComponent(0.2))
                color.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }

            return true
        }
        img.isTemplate = false
        button.image = img
    }

    // MARK: - Theme Change

    /// The status icon bakes the menu bar color into a non-template image
    /// (needed for the colored feature dots) — so it must be redrawn when
    /// the system switches between light and dark.
    private func registerForThemeChange() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Small delay lets effectiveAppearance settle before redrawing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.updateStatusIcon()
            }
        }
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
                self.scrollReverser.stop()
                self.scrollReverser.isEnabled = true
            }
            self.buttonRemapper.restart()
            self.capsLock.reapplyIfNeeded()
            // Full restart (not just re-enable) — matches the recovery
            // strength of the other managers after wake.
            self.fnKey.restart()
        }
    }
}
