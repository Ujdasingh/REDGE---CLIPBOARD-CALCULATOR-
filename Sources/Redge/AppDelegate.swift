import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var clipboardManager: ClipboardManager!
    private var clipboardWindow: ClipboardWindow!
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    private var hideTimer: Timer?
    private var panelHotKey: HotKey?
    private var repeatHotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()

    private let pollInterval: TimeInterval = 0.05

    func applicationDidFinishLaunching(_ notification: Notification) {
        clipboardManager = ClipboardManager()
        clipboardManager.start()

        clipboardWindow = ClipboardWindow(clipboardManager: clipboardManager)
        if RepeatEngine.shared.isEnabled {
            RepeatEngine.shared.start()
        }

        setupStatusItem()
        startMousePolling()
        registerHotKeys()
        NotificationCenter.default.publisher(for: AppSettings.hotkeysChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.registerHotKeys() }
            .store(in: &cancellables)
        Onboarding.showIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardManager.flushSave()
        RepeatEngine.shared.stop()
    }

    private func registerHotKeys() {
        let settings = AppSettings.shared
        panelHotKey = HotKey(
            keyCode: settings.panelKeyCode,
            modifiers: settings.panelCarbonMods
        ) { [weak self] in
            self?.toggleViaHotkey()
        }
        repeatHotKey = HotKey(
            keyCode: settings.repeatKeyCode,
            modifiers: settings.repeatCarbonMods
        ) {
            RepeatEngine.shared.replay()
        }
    }

    private func toggleViaHotkey() {
        let location = NSEvent.mouseLocation
        let screen = screenContaining(point: location) ?? NSScreen.main
        guard let s = screen else { return }
        if clipboardWindow.isVisible {
            clipboardWindow.hide()
        } else {
            clipboardWindow.show(on: s)
            clipboardManager.requestSearchFocus()
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let icon = NSApp.applicationIconImage?.copy() as? NSImage {
                icon.size = NSSize(width: 18, height: 18)
                button.image = icon
            } else {
                button.image = NSImage(
                    systemSymbolName: "doc.on.clipboard",
                    accessibilityDescription: "Redge — Clipboard & Calculator"
                )
            }
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Show Clipboard", action: #selector(showClipboard), keyEquivalent: ""))
        let repeatItem = NSMenuItem(title: "Repeat Last", action: #selector(repeatLast), keyEquivalent: "")
        repeatItem.identifier = NSUserInterfaceItemIdentifier("repeatLast")
        menu.addItem(repeatItem)
        menu.addItem(NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(.separator())
        let repeatToggle = NSMenuItem(title: "Remember Last Action", action: #selector(toggleRepeat(_:)), keyEquivalent: "")
        repeatToggle.identifier = NSUserInterfaceItemIdentifier("repeatEnabled")
        repeatToggle.state = RepeatEngine.shared.isEnabled ? .on : .off
        menu.addItem(repeatToggle)
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.identifier = NSUserInterfaceItemIdentifier("launchAtLogin")
        launchItem.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Privacy Settings…", action: #selector(openPrivacySettings), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Redge", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                print("Launch at login toggle failed: \(error)")
            }
            sender.state = isLaunchAtLoginEnabled ? .on : .off
        }
    }

    private var isLaunchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    private func startMousePolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.checkMousePosition()
        }
    }

    private func checkMousePosition() {
        if ScreenshotGuard.isActive {
            if clipboardWindow.isVisible {
                cancelHide()
            }
            return
        }

        let location = NSEvent.mouseLocation
        guard let screen = screenContaining(point: location) else { return }
        let frame = screen.frame
        let settings = AppSettings.shared
        let threshold = CGFloat(settings.edgeThreshold)
        let isAtEdge: Bool
        switch settings.edgeSide {
        case .right:
            isAtEdge = location.x >= frame.maxX - threshold
        case .left:
            isAtEdge = location.x <= frame.minX + threshold
        }
        let halfRange = frame.height * CGFloat(settings.verticalRangeFraction) / 2
        let isInVerticalCenter = abs(location.y - frame.midY) < halfRange
        let isAtTrigger = isAtEdge && isInVerticalCenter
        let isOverWindow = clipboardWindow.containsMouse(at: location)

        if isAtTrigger {
            cancelHide()
            clipboardWindow.show(on: screen)
        } else if isOverWindow {
            cancelHide()
        } else if clipboardWindow.isVisible {
            if clipboardManager.isFrozen {
                cancelHide()
            } else {
                scheduleHide()
            }
        }
    }

    private func screenContaining(point: NSPoint) -> NSScreen? {
        return NSScreen.screens.first { NSPointInRect(point, $0.frame) } ?? NSScreen.main
    }

    private func scheduleHide() {
        guard hideTimer == nil else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: AppSettings.shared.hideDelay, repeats: false) { [weak self] _ in
            self?.hideTimer = nil
            self?.clipboardWindow.hide()
        }
    }

    private func cancelHide() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    @objc private func showClipboard() {
        let location = NSEvent.mouseLocation
        let screen = screenContaining(point: location) ?? NSScreen.main
        guard let s = screen else { return }
        clipboardWindow.show(on: s)
    }

    @objc private func repeatLast() {
        RepeatEngine.shared.replay()
    }

    @objc private func toggleRepeat(_ sender: NSMenuItem) {
        RepeatEngine.shared.isEnabled.toggle()
        sender.state = RepeatEngine.shared.isEnabled ? .on : .off
        if RepeatEngine.shared.isEnabled && !AutoPaste.isAccessibilityTrusted {
            AutoPaste.requestAccessibility()
        }
    }

    @objc private func openSettings() {
        SettingsWindow.shared.show()
    }

    @objc private func checkForUpdates() {
        UpdateChecker.check()
    }

    @objc private func clearHistory() {
        clipboardManager.clearHistory()
    }

    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if let item = menu.items.first(where: { $0.identifier?.rawValue == "launchAtLogin" }) {
            item.state = isLaunchAtLoginEnabled ? .on : .off
        }
        if let item = menu.items.first(where: { $0.identifier?.rawValue == "repeatEnabled" }) {
            item.state = RepeatEngine.shared.isEnabled ? .on : .off
        }
        if let item = menu.items.first(where: { $0.identifier?.rawValue == "repeatLast" }) {
            let preview = RepeatEngine.shared.preview
            let shortcut = AppSettings.shared.repeatHotkeyLabel
            item.title = preview.isEmpty
                ? "Repeat Last    \(shortcut)"
                : "Repeat “\(preview)”    \(shortcut)"
            item.isEnabled = RepeatEngine.shared.isEnabled
        }
    }
}
