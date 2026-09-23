import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

final class SettingsWindow {
    static let shared = SettingsWindow()
    private var panel: NSPanel?

    func show() {
        if panel == nil {
            let panel = FocusableNSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Redge Settings"
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = false
            let host = NSHostingView(rootView: SettingsView())
            host.frame = NSRect(x: 0, y: 0, width: 420, height: 560)
            panel.contentView = host
            self.panel = panel
        }
        NSApp.activate(ignoringOtherApps: true)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel?.setFrameOrigin(NSPoint(x: f.midX - 210, y: f.midY - 260))
        }
        panel?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var repeater = RepeatEngine.shared
    @State private var recording: RecordingTarget?

    private enum RecordingTarget { case panel, repeatHotkey }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Panel") {
                    Picker("Screen edge", selection: $settings.edgeSide) {
                        ForEach(PanelEdge.allCases) { edge in
                            Text(edge.title).tag(edge)
                        }
                    }
                    .pickerStyle(.segmented)
                    labeledSlider("Edge thickness", value: $settings.edgeThreshold, range: 2...16, format: "%.0f px")
                    labeledSlider("Trigger height", value: $settings.verticalRangeFraction, range: 0.25...1.0, format: "%.0f%%") { $0 * 100 }
                    labeledSlider("Hide delay", value: $settings.hideDelay, range: 0.1...1.0, format: "%.2f s")
                    Stepper("History size: \(settings.historyLimit)", value: $settings.historyLimit, in: 10...200, step: 10)
                    Toggle("Auto-paste on click", isOn: $settings.autoPasteEnabled)
                    Text("Fills the selected Excel cell when possible. Needs Accessibility.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                section("Shortcuts") {
                    hotkeyRow("Open panel", label: settings.panelHotkeyLabel, target: .panel)
                    hotkeyRow("Repeat last", label: settings.repeatHotkeyLabel, target: .repeatHotkey)
                    if recording != nil {
                        Text("Press the new shortcut now…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.accentColor)
                    }
                }

                section("Repeat") {
                    Toggle("Enable Repeat (⌘⌥R and action recording)", isOn: $repeater.isEnabled)
                    Text("Off by default. Turn on only if you need last-action replay. Uses Accessibility and Input Monitoring.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    if repeater.isEnabled {
                        HStack {
                            Button("Open Accessibility") { openPrivacy("Privacy_Accessibility") }
                            Button("Open Input Monitoring") { openPrivacy("Privacy_ListenEvent") }
                        }
                    }
                }

                section("Notes") {
                    HStack {
                        Button("Export Notes…") { exportNotes() }
                        Button("Import Notes…") { importNotes() }
                    }
                }

                section("Updates & signing") {
                    Text("Current version \(UpdateChecker.currentVersion)")
                        .font(.system(size: 11))
                    Button("Check for Updates") { UpdateChecker.check() }
                    Text("Notarized updates need an Apple Developer ID. Until then, download releases from GitHub.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Button("Open Releases") { NSWorkspace.shared.open(UpdateChecker.releasesURL) }
                }

                section("Login") {
                    Toggle("Launch at login", isOn: launchAtLoginBinding)
                }
            }
            .padding(18)
        }
        .frame(width: 420, height: 560)
        .background(
            KeyCaptureView(isArmed: recording != nil) { event in
                guard let target = recording else { return }
                settings.applyHotkey(panel: target == .panel, event: event)
                recording = nil
            }
        )
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            content()
            Divider()
        }
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String, transform: @escaping (Double) -> Double = { $0 }) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, transform(value.wrappedValue)))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            .font(.system(size: 11))
            Slider(value: value, in: range)
        }
    }

    private func hotkeyRow(_ title: String, label: String, target: RecordingTarget) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            Button("Record") { recording = target }
                .controlSize(.small)
        }
        .font(.system(size: 12))
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: {
                if #available(macOS 13.0, *) {
                    return SMAppService.mainApp.status == .enabled
                }
                return false
            },
            set: { on in
                guard #available(macOS 13.0, *) else { return }
                do {
                    if on { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                } catch {
                    print("Launch at login failed: \(error)")
                }
            }
        )
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func exportNotes() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "redge-notes.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ClipboardManager.shared?.exportNotes(to: url)
    }

    private func importNotes() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ClipboardManager.shared?.importNotes(from: url)
    }
}

/// Invisible view that captures the next key-down while recording a shortcut.
struct KeyCaptureView: NSViewRepresentable {
    let isArmed: Bool
    let onKey: (NSEvent) -> Void

    func makeNSView(context: Context) -> KeyCatcher {
        let view = KeyCatcher()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: KeyCatcher, context: Context) {
        nsView.onKey = onKey
        nsView.isArmed = isArmed
        if isArmed {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class KeyCatcher: NSView {
        var onKey: ((NSEvent) -> Void)?
        var isArmed = false
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            guard isArmed else { return super.keyDown(with: event) }
            onKey?(event)
        }
    }
}
