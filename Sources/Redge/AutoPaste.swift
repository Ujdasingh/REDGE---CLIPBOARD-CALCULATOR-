import AppKit
import ApplicationServices
import CoreGraphics

enum AutoPaste {
    private static let defaultsKey = "autoPasteEnabled"

    static func isEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: defaultsKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: defaultsKey)
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

    static func paste(into app: NSRunningApplication?, content: ClipboardContent) {
        if !isAccessibilityTrusted {
            requestAccessibility()
        }

        let target = resolvedTarget(app)
        activate(target)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            activate(target)
            let bid = target?.bundleIdentifier ?? ""

            if case .text(let text) = content, !text.isEmpty {
                if bid == "com.microsoft.Excel" || bid.lowercased().contains("excel") {
                    if fillExcel(text) { return }
                }
                if bid == "com.apple.iWork.Numbers" {
                    if fillNumbers(text) { return }
                }
            }

            sendCmdV(to: target)
        }
    }

    private static func resolvedTarget(_ app: NSRunningApplication?) -> NSRunningApplication? {
        if let app, app.bundleIdentifier != Bundle.main.bundleIdentifier, !app.isTerminated {
            return app
        }
        return NSWorkspace.shared.runningApplications.first {
            $0.isActive && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
    }

    private static func activate(_ app: NSRunningApplication?) {
        guard let app else { return }
        app.activate(options: [.activateIgnoringOtherApps])
    }

    private static func sendCmdV(to app: NSRunningApplication?) {
        let src = CGEventSource(stateID: .hidSystemState)
        let v: CGKeyCode = 0x09
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        if let pid = app?.processIdentifier, pid != 0 {
            down.postToPid(pid)
            up.postToPid(pid)
        } else {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    @discardableResult
    private static func fillExcel(_ text: String) -> Bool {
        let escaped = escapeAppleScript(text)
        let script = """
        tell application "Microsoft Excel"
            try
                activate
                set value of selection to "\(escaped)"
                return "ok"
            on error
                return "fail"
            end try
        end tell
        """
        return runAppleScript(script) == "ok"
    }

    @discardableResult
    private static func fillNumbers(_ text: String) -> Bool {
        let escaped = escapeAppleScript(text)
        let script = """
        tell application "Numbers"
            try
                activate
                tell front document
                    tell active sheet
                        tell first table
                            set value of selection to "\(escaped)"
                        end tell
                    end tell
                end tell
                return "ok"
            on error
                return "fail"
            end try
        end tell
        """
        return runAppleScript(script) == "ok"
    }

    private static func escapeAppleScript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue ?? "ok"
    }
}
