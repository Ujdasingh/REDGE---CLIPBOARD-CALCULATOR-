import AppKit
import CoreGraphics
import SwiftUI

enum Onboarding {
    static func showIfNeeded() {
        if AppSettings.shared.onboardingDone { return }
        // Existing installs already chose Repeat via the menu; don't re-prompt.
        if UserDefaults.standard.object(forKey: "repeatLastEnabled") != nil {
            AppSettings.shared.onboardingDone = true
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            present()
        }
    }

    static func present() {
        let alert = NSAlert()
        alert.messageText = "How do you want to use Redge?"
        alert.informativeText = "Clipboard only works immediately: history, OCR, calculator, and Auto-paste.\n\nClipboard + Repeat also records shortcuts and last actions. It needs Accessibility and Input Monitoring. Leave this off unless you want ⌘⌥R."
        alert.addButton(withTitle: "Clipboard only")
        alert.addButton(withTitle: "Clipboard + Repeat")
        NSApp.activate(ignoringOtherApps: true)
        let result = alert.runModal()
        AppSettings.shared.onboardingDone = true
        if result == .alertSecondButtonReturn {
            RepeatEngine.shared.isEnabled = true
            AutoPaste.requestAccessibility()
            CGRequestListenEventAccess()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        } else {
            RepeatEngine.shared.isEnabled = false
        }
    }
}
