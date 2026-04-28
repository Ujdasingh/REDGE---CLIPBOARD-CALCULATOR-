import AppKit
import ApplicationServices
import CoreGraphics

enum AutoPaste {
    private static let defaultsKey = "autoPasteEnabled"

    static func isEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
    }

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func paste(into app: NSRunningApplication?) {
        guard isAccessibilityTrusted else { return }
        if let app = app {
            app.activate(options: [])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            sendCmdV()
        }
    }

    private static func sendCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let kVK_ANSI_V: CGKeyCode = 0x09
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: kVK_ANSI_V, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: kVK_ANSI_V, keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
