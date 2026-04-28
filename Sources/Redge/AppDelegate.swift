import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var clipboardManager: ClipboardManager!
    private var clipboardWindow: ClipboardWindow!
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    private var hideTimer: Timer?
    private var hotKey: HotKey?

    private let edgeThreshold: CGFloat = 3
    private let verticalRangeFraction: CGFloat = 0.5
    private let pollInterval: TimeInterval = 0.05
    private let hideDelay: TimeInterval = 0.25

    func applicationDidFinishLaunching(_ notification: Notification) {
        clipboardManager = ClipboardManager()
        clipboardManager.start()

        clipboardWindow = ClipboardWindow(clipboardManager: clipboardManager)

        setupStatusItem()
        startMousePolling()
        registerHotKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardManager.flushSave()
    }

    private func registerHotKey() {
        let modifiers = UInt32(controlKey | cmdKey)
        let keyV = UInt32(kVK_ANSI_V)
        hotKey = HotKey(keyCode: keyV, modifiers: modifiers) { [weak self] in
            self?.toggleViaHotkey()
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
            button.image = NSImage(
                systemSymbolName: "doc.on.clipboard",
                accessibilityDescription: "Redge — Clipboard & Calculator"
            )
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Show Clipboard", action: #selector(showClipboard), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: ""))
        menu.addItem(.separator())
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.identifier = NSUserInterfaceItemIdentifier("launchAtLogin")
        launchItem.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)
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
        let location = NSEvent.mouseLocation
        guard let screen = screenContaining(point: location) else { return }
        let frame = screen.frame

        let isAtRightEdge = location.x >= frame.maxX - edgeThreshold
        let halfRange = frame.height * verticalRangeFraction / 2
        let isInVerticalCenter = abs(location.y - frame.midY) < halfRange
        let isAtTrigger = isAtRightEdge && isInVerticalCenter
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
        hideTimer = Timer.scheduledTimer(withTimeInterval: hideDelay, repeats: false) { [weak self] _ in
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

    @objc private func clearHistory() {
        clipboardManager.clearHistory()
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
    }
}
