import AppKit
import Carbon.HIToolbox
import Combine

enum PanelEdge: String, CaseIterable, Identifiable {
    case right, left
    var id: String { rawValue }
    var title: String { self == .right ? "Right" : "Left" }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let hotkeysChanged = Notification.Name("RedgeHotkeysChanged")

    @Published var edgeSide: PanelEdge {
        didSet { d.set(edgeSide.rawValue, forKey: Keys.edgeSide) }
    }
    @Published var edgeThreshold: Double {
        didSet { d.set(edgeThreshold, forKey: Keys.edgeThreshold) }
    }
    @Published var verticalRangeFraction: Double {
        didSet { d.set(verticalRangeFraction, forKey: Keys.verticalRange) }
    }
    @Published var hideDelay: Double {
        didSet { d.set(hideDelay, forKey: Keys.hideDelay) }
    }
    @Published var historyLimit: Int {
        didSet { d.set(historyLimit, forKey: Keys.historyLimit) }
    }
    @Published var autoPasteEnabled: Bool {
        didSet {
            d.set(autoPasteEnabled, forKey: Keys.autoPaste)
            AutoPaste.setEnabled(autoPasteEnabled)
        }
    }
    @Published var panelKeyCode: UInt32 {
        didSet { persistHotkeys() }
    }
    @Published var panelCarbonMods: UInt32 {
        didSet { persistHotkeys() }
    }
    @Published var repeatKeyCode: UInt32 {
        didSet { persistHotkeys() }
    }
    @Published var repeatCarbonMods: UInt32 {
        didSet { persistHotkeys() }
    }

    var onboardingDone: Bool {
        get { d.bool(forKey: Keys.onboarding) }
        set { d.set(newValue, forKey: Keys.onboarding) }
    }

    var panelHotkeyLabel: String {
        Self.label(keyCode: panelKeyCode, carbon: panelCarbonMods)
    }
    var repeatHotkeyLabel: String {
        Self.label(keyCode: repeatKeyCode, carbon: repeatCarbonMods)
    }

    private let d = UserDefaults.standard
    private enum Keys {
        static let edgeSide = "settings.edgeSide"
        static let edgeThreshold = "settings.edgeThreshold"
        static let verticalRange = "settings.verticalRange"
        static let hideDelay = "settings.hideDelay"
        static let historyLimit = "settings.historyLimit"
        static let autoPaste = "autoPasteEnabled"
        static let onboarding = "settings.onboardingDone"
        static let panelKey = "settings.panelKeyCode"
        static let panelMods = "settings.panelCarbonMods"
        static let repeatKey = "settings.repeatKeyCode"
        static let repeatMods = "settings.repeatCarbonMods"
    }

    private init() {
        let storedEdge = d.string(forKey: Keys.edgeSide) ?? PanelEdge.right.rawValue
        edgeSide = PanelEdge(rawValue: storedEdge) ?? .right
        edgeThreshold = d.object(forKey: Keys.edgeThreshold) == nil ? 3 : d.double(forKey: Keys.edgeThreshold)
        verticalRangeFraction = d.object(forKey: Keys.verticalRange) == nil ? 0.5 : d.double(forKey: Keys.verticalRange)
        hideDelay = d.object(forKey: Keys.hideDelay) == nil ? 0.25 : d.double(forKey: Keys.hideDelay)
        historyLimit = d.object(forKey: Keys.historyLimit) == nil ? 50 : d.integer(forKey: Keys.historyLimit)
        if d.object(forKey: Keys.autoPaste) == nil {
            autoPasteEnabled = true
            d.set(true, forKey: Keys.autoPaste)
        } else {
            autoPasteEnabled = d.bool(forKey: Keys.autoPaste)
        }
        panelKeyCode = d.object(forKey: Keys.panelKey) == nil
            ? UInt32(kVK_ANSI_V) : UInt32(d.integer(forKey: Keys.panelKey))
        panelCarbonMods = d.object(forKey: Keys.panelMods) == nil
            ? UInt32(controlKey | cmdKey) : UInt32(d.integer(forKey: Keys.panelMods))
        repeatKeyCode = d.object(forKey: Keys.repeatKey) == nil
            ? UInt32(kVK_ANSI_R) : UInt32(d.integer(forKey: Keys.repeatKey))
        repeatCarbonMods = d.object(forKey: Keys.repeatMods) == nil
            ? UInt32(cmdKey | optionKey) : UInt32(d.integer(forKey: Keys.repeatMods))
    }

    func applyHotkey(panel: Bool, event: NSEvent) {
        let carbon = Self.carbon(from: event.modifierFlags)
        guard carbon != 0 else { return }
        if panel {
            panelKeyCode = UInt32(event.keyCode)
            panelCarbonMods = carbon
        } else {
            repeatKeyCode = UInt32(event.keyCode)
            repeatCarbonMods = carbon
        }
    }

    private func persistHotkeys() {
        d.set(Int(panelKeyCode), forKey: Keys.panelKey)
        d.set(Int(panelCarbonMods), forKey: Keys.panelMods)
        d.set(Int(repeatKeyCode), forKey: Keys.repeatKey)
        d.set(Int(repeatCarbonMods), forKey: Keys.repeatMods)
        NotificationCenter.default.post(name: Self.hotkeysChanged, object: nil)
    }

    static func carbon(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let f = flags.intersection(.deviceIndependentFlagsMask)
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    static func label(keyCode: UInt32, carbon: UInt32) -> String {
        var s = ""
        if carbon & UInt32(controlKey) != 0 { s += "⌃" }
        if carbon & UInt32(optionKey) != 0 { s += "⌥" }
        if carbon & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbon & UInt32(cmdKey) != 0 { s += "⌘" }
        s += keyName(keyCode)
        return s
    }

    private static func keyName(_ code: UInt32) -> String {
        let map: [UInt32: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
            0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
            0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1",
            0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x19: "9",
            0x1A: "7", 0x1C: "8", 0x1D: "0", 0x1F: "O", 0x20: "U", 0x22: "I",
            0x23: "P", 0x25: "L", 0x26: "J", 0x28: "K", 0x2D: "N", 0x2E: "M",
            0x31: "Space", 0x24: "↩", 0x30: "⇥"
        ]
        return map[code] ?? "Key"
    }
}
