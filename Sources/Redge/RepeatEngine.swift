import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import CoreGraphics

/// Replays the last shortcut, a shortcut plus a move within 3 seconds, a
/// Finder drop into a folder, or the last typed value.
final class RepeatEngine: ObservableObject {
    static let shared = RepeatEngine()

    @Published private(set) var lastText: String?
    @Published private(set) var lastActionTick = 0
    @Published private(set) var accessibilityReady = false
    @Published private(set) var captureReady = false
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { start() } else { stop() }
        }
    }

    var preview: String {
        _ = lastActionTick
        let chordAt = lastChord?.at ?? 0
        let gestureAt = lastGesture?.at ?? 0
        let finderAt = lastFinderAt
        if finderAt > 0, finderAt >= chordAt, finderAt >= gestureAt, finderAt >= lastTextAt, lastFinderDest != nil {
            return "move to folder"
        }
        if chordAt >= lastTextAt || gestureAt >= lastTextAt {
            var label = lastChord?.label ?? ""
            if let g = lastGesture, abs(g.at - (lastChord?.at ?? g.at)) <= Self.actionWindow {
                label = label.isEmpty ? "move" : label + "+move"
            } else if gestureAt > chordAt {
                label = "move"
            }
            if !label.isEmpty { return label }
        }
        guard let text = lastText, !text.isEmpty else { return "" }
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        if oneLine.count <= 28 { return oneLine }
        return String(oneLine.prefix(27)) + "…"
    }

    private static let enabledKey = "repeatLastEnabled"
    private static let maxLength = 500
    private static let actionWindow: TimeInterval = 3

    private var pollTimer: Timer?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    private var lastFocusUID = ""
    private var lastFocusPID: pid_t = 0
    private var valueAtFocusEnter = ""
    private var typedSession = ""
    private var lastTypeAt: TimeInterval = 0
    private var lastTextAt: TimeInterval = 0
    private var lastSeenKey: (code: UInt16, time: TimeInterval) = (0, 0)
    private var lastMouseAt: TimeInterval = 0
    private var isRunning = false
    private var isReplaying = false
    private var lastReplayAt: TimeInterval = 0
    private var hudPanel: NSPanel?
    private var hudHideWork: DispatchWorkItem?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var sleepObservers: [NSObjectProtocol] = []
    private var suspendedForSleep = false
    private var permTick = 0
    private var globalMouseMonitor: Any?

    private var dragStart: CGPoint?
    private var dragFlags: CGEventFlags = []
    private var lastGesture: PointerAction?
    private var lastChord: LastChord?
    private var finderDragSource: String?
    private var lastFinderDest: String?
    private var lastFinderAt: TimeInterval = 0

    private struct PointerAction {
        var dx: CGFloat
        var dy: CGFloat
        var flags: CGEventFlags
        var at: TimeInterval
    }

    private struct LastChord {
        var keyCode: CGKeyCode
        var flags: CGEventFlags
        var at: TimeInterval
        var label: String
    }

    private init() {
        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            isEnabled = false
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
    }

    func start() {
        guard isEnabled, !isRunning else { return }
        isRunning = true
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { [weak self] _ in
            self?.pollFocus()
            self?.permTick += 1
            if let tick = self?.permTick, tick % 5 == 0 {
                self?.refreshPermissions()
            }
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(
                code: event.keyCode,
                characters: event.characters ?? "",
                modifiers: event.modifierFlags,
                timestamp: event.timestamp
            )
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(
                code: event.keyCode,
                characters: event.characters ?? "",
                modifiers: event.modifierFlags,
                timestamp: event.timestamp
            )
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let cg = event.cgEvent else { return }
            let type: CGEventType = event.type == .leftMouseDown ? .leftMouseDown : .leftMouseUp
            self?.handleMouse(type: type, event: cg)
        }
        CGRequestListenEventAccess()
        installListenTap()
        observeSleepWake()
        refreshPermissions()
    }

    func stop() {
        isRunning = false
        pollTimer?.invalidate()
        pollTimer = nil
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m) }
        globalKeyMonitor = nil
        localKeyMonitor = nil
        globalMouseMonitor = nil
        teardownListenTap()
        let center = NSWorkspace.shared.notificationCenter
        for observer in sleepObservers {
            center.removeObserver(observer)
        }
        sleepObservers.removeAll()
        suspendedForSleep = false
    }

    func refreshPermissions() {
        accessibilityReady = AXIsProcessTrusted()
        guard isRunning, !suspendedForSleep else { return }
        if let tap = eventTap, CGEvent.tapIsEnabled(tap: tap) {
            captureReady = true
            return
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            if CGEvent.tapIsEnabled(tap: tap) {
                captureReady = true
                return
            }
            teardownListenTap()
        }
        installListenTap()
    }

    /// Listen-only, keys only. Never insert into the click stream.
    private func installListenTap() {
        guard !suspendedForSleep else { return }
        if let existing = eventTap, CGEvent.tapIsEnabled(tap: existing) {
            captureReady = true
            return
        }
        teardownListenTap()

        let mask: CGEventMask =
            (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.tapDisabledByTimeout.rawValue) |
            (CGEventMask(1) << CGEventType.tapDisabledByUserInput.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                RepeatEngine.shared.handleTap(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            captureReady = false
            return
        }
        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTapSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        captureReady = CGEvent.tapIsEnabled(tap: tap)
    }

    /// Drop the tap and its run-loop source together. Replacing a disabled tap
    /// without this leaks mach ports until the process is killed.
    private func teardownListenTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        eventTapSource = nil
        captureReady = false
    }

    private func observeSleepWake() {
        guard sleepObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.suspendForSleep()
        })
        sleepObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resumeAfterWake()
        })
    }

    private func suspendForSleep() {
        suspendedForSleep = true
        teardownListenTap()
    }

    private func resumeAfterWake() {
        // Accessibility positions are often NaN for a moment after the lid opens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.isRunning else { return }
            self.suspendedForSleep = false
            self.installListenTap()
        }
    }

    private func handleTap(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                captureReady = CGEvent.tapIsEnabled(tap: tap)
            }
            return
        }
        guard type == .keyDown else { return }

        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        var flags = NSEvent.ModifierFlags()
        if event.flags.contains(.maskShift) { flags.insert(.shift) }
        if event.flags.contains(.maskCommand) { flags.insert(.command) }
        if event.flags.contains(.maskControl) { flags.insert(.control) }
        if event.flags.contains(.maskAlternate) { flags.insert(.option) }

        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        var chars = ""
        if length > 0 {
            var buffer = [UniChar](repeating: 0, count: length)
            event.keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: &buffer)
            chars = String(utf16CodeUnits: buffer, count: length)
        }
        let timestamp = ProcessInfo.processInfo.systemUptime

        DispatchQueue.main.async { [weak self] in
            self?.handleKey(code: code, characters: chars, modifiers: flags, timestamp: timestamp)
        }
    }

    func replay() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastReplayAt < 0.4 { return }
        lastReplayAt = now

        guard isEnabled else { return }
        if !AXIsProcessTrusted() {
            AutoPaste.requestAccessibility()
            refreshPermissions()
            showHUD("Turn on Accessibility for Redge")
        }
        if !captureReady {
            CGRequestListenEventAccess()
            installListenTap()
        }

        let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        log("replay front=\(bid) ax=\(AXIsProcessTrusted()) capture=\(captureReady) chord=\(lastChord?.label ?? "-") gesture=\(lastGesture != nil) finder=\(lastFinderDest ?? "-")")

        if !typedSession.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            remember(typedSession)
            typedSession = ""
        }

        let chordAt = lastChord?.at ?? 0
        let gestureAt = lastGesture?.at ?? 0
        let finderAt = lastFinderAt
        let textAt = lastTextAt
        let latest = max(chordAt, gestureAt, finderAt, textAt)
        if latest == 0 {
            showHUD(captureReady ? "Do an action first, then ⌘⌥R" : "Turn on Input Monitoring for Redge")
            NSSound.beep()
            return
        }

        if bid == "com.apple.finder",
           let dest = lastFinderDest,
           finderAt >= chordAt, finderAt >= gestureAt, finderAt >= textAt {
            isReplaying = true
            showHUD("Moving to folder")
            moveFinderSelection(to: dest)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.isReplaying = false
            }
            return
        }

        let moveWithChord = lastChord != nil && lastGesture != nil
            && abs(gestureAt - chordAt) <= Self.actionWindow
        if chordAt >= textAt || (moveWithChord && gestureAt >= textAt) {
            if lastChord != nil {
                replayChord(alsoMove: moveWithChord)
                return
            }
        }
        if gestureAt >= textAt, lastGesture != nil {
            replayLastGesture()
            return
        }

        guard let text = lastText, !text.isEmpty else {
            NSSound.beep()
            return
        }

        isReplaying = true

        let finish = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                guard let self = self else { return }
                self.typedSession = ""
                self.valueAtFocusEnter = text
                self.isReplaying = false
            }
        }

        if bid == "com.apple.finder" {
            renameFinderSelection(to: text)
            finish()
            return
        }
        // Excel keeps its own clipboard. Cmd+V pastes the last copied row
        // (the "earlier one") instead of the value Repeat just captured.
        if bid == "com.microsoft.Excel" || bid.lowercased().contains("excel") {
            if !fillExcel(text) {
                typeTextByCharacter(text)
            }
            finish()
            return
        }
        if bid == "com.apple.iWork.Numbers" {
            if !fillNumbers(text) {
                typeTextByCharacter(text)
            }
            finish()
            return
        }
        typeTextByCharacter(text)
        finish()
    }

    // MARK: - Capture

    /// Excel / Finder often do not publish in-progress edits to Accessibility.
    /// Keep a short per-field typing buffer so the *latest* entry becomes Repeat.
    private func handleKey(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags, timestamp: TimeInterval) {
        guard isEnabled, !isReplaying else { return }
        if isOurPanelKey() { return }

        if code == lastSeenKey.code, abs(ProcessInfo.processInfo.systemUptime - lastSeenKey.time) < 0.03 {
            return
        }
        lastSeenKey = (code, ProcessInfo.processInfo.systemUptime)

        let mods = modifiers.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if Self.isBareModifier(code) { return }
        if Self.isOurRepeatShortcut(code: code, mods: mods) {
            replay()
            return
        }
        if code == 0x30 && mods.contains(.command) { return } // Cmd+Tab
        if code == 0x32 && mods.contains(.command) && !mods.contains(.control) && !mods.contains(.option) { return } // Cmd+`

        if !mods.subtracting(.shift).isEmpty {
            recordChord(code: code, mods: mods)
            return
        }

        switch code {
        case 36, 76, 48: // Return, keypad Enter, Tab
            commitTypedSession()
            return
        case 53: // Escape
            typedSession = ""
            return
        case 51: // Delete
            if !typedSession.isEmpty { typedSession.removeLast() }
            return
        case 117: // Forward delete
            return
        default:
            break
        }

        guard !characters.isEmpty else { return }
        for ch in characters {
            if ch == "\t" || ch == "\r" || ch == "\n" { continue }
            if ch.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) { continue }
            typedSession.append(ch)
        }
        if typedSession.count > Self.maxLength {
            typedSession = String(typedSession.suffix(Self.maxLength))
        }
        lastTypeAt = ProcessInfo.processInfo.systemUptime
    }

    private func recordChord(code: UInt16, mods: NSEvent.ModifierFlags) {
        var flags: CGEventFlags = []
        if mods.contains(.command) { flags.insert(.maskCommand) }
        if mods.contains(.control) { flags.insert(.maskControl) }
        if mods.contains(.option) { flags.insert(.maskAlternate) }
        if mods.contains(.shift) { flags.insert(.maskShift) }
        lastChord = LastChord(
            keyCode: CGKeyCode(code),
            flags: flags,
            at: ProcessInfo.processInfo.systemUptime,
            label: Self.shortcutLabel(code: code, mods: mods)
        )
        lastActionTick += 1
        log("captured \(lastChord?.label ?? "")")
    }

    private static func isBareModifier(_ code: UInt16) -> Bool {
        switch code {
        case 0x36, 0x37, 0x38, 0x3A, 0x3B, 0x3C, 0x3D, 0x3F: return true
        default: return false
        }
    }

    private static func isOurRepeatShortcut(code: UInt16, mods: NSEvent.ModifierFlags) -> Bool {
        let stripped = mods.subtracting(.numericPad)
        return code == 0x0F && stripped.contains(.command) && stripped.contains(.option) && !stripped.contains(.control)
    }

    private static func shortcutLabel(code: UInt16, mods: NSEvent.ModifierFlags) -> String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        s += Self.keyName(code)
        return s
    }

    private static func keyName(_ code: UInt16) -> String {
        let map: [UInt16: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
            0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
            0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1",
            0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x19: "9",
            0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1F: "O", 0x20: "U",
            0x22: "I", 0x23: "P", 0x25: "L", 0x26: "J", 0x28: "K", 0x2D: "N",
            0x2E: "M", 0x31: "Space", 0x24: "↩", 0x30: "⇥", 0x33: "⌫",
            0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5",
            0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10"
        ]
        return map[code] ?? "Key"
    }

    private func commitTypedSession() {
        let fromKeys = typedSession.trimmingCharacters(in: .whitespacesAndNewlines)
        typedSession = ""
        // Never fall back to the Accessibility field value — that is often an
        // old cell (the "random number from the past"). Repeat is last typing only.
        remember(fromKeys)
    }

    private func pollFocus() {
        guard isEnabled, !isReplaying, !suspendedForSleep, AutoPaste.isAccessibilityTrusted else { return }
        guard !NSScreen.screens.isEmpty else { return }
        if isOurPanelKey() { return }

        guard let info = Self.focusedField() else { return }
        let pid = Self.pidOfFocused() ?? lastFocusPID
        if lastFocusPID != 0, pid != lastFocusPID {
            commitTypedSession()
        }
        lastFocusUID = info.uid
        lastFocusPID = pid
        if typedSession.isEmpty {
            valueAtFocusEnter = info.value
        }
    }

    private func remember(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.shouldRemember(text) else { return }
        lastText = text
        lastTextAt = ProcessInfo.processInfo.systemUptime
        lastActionTick += 1
    }

    private static func shouldRemember(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= maxLength else { return false }
        if text.count == 1, text.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
            return false
        }
        return true
    }

    private func isOurPanelKey() -> Bool {
        NSApp.windows.contains { $0.isKeyWindow && $0 is FocusableNSPanel }
    }

    private func isPointOnOurUI() -> Bool {
        let mouse = NSEvent.mouseLocation
        return NSApp.windows.contains { win in
            (win is FocusableNSPanel || win is NSPanel) && win.frame.contains(mouse)
        }
    }

    private func handleMouse(type: CGEventType, event: CGEvent) {
        guard isEnabled, !isReplaying else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMouseAt < 0.02 { return }
        lastMouseAt = now
        let location = event.location
        let eventFlags = event.flags
        let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""

        if type == .leftMouseDown {
            if isPointOnOurUI() {
                dragStart = nil
                finderDragSource = nil
                return
            }
            dragStart = location
            dragFlags = eventFlags
            finderDragSource = nil
            if bid == "com.apple.finder" {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.dragStart != nil else { return }
                    self.finderDragSource = self.finderContainerPOSIX()
                }
            }
            return
        }

        guard type == .leftMouseUp, let start = dragStart else { return }
        dragStart = nil
        let dx = location.x - start.x
        let dy = location.y - start.y
        if hypot(dx, dy) >= 8 {
            var flags: CGEventFlags = []
            if dragFlags.contains(.maskAlternate) || eventFlags.contains(.maskAlternate) { flags.insert(.maskAlternate) }
            if dragFlags.contains(.maskShift) || eventFlags.contains(.maskShift) { flags.insert(.maskShift) }
            lastGesture = PointerAction(dx: dx, dy: dy, flags: flags, at: now)
            lastActionTick += 1
        }

        if bid == "com.apple.finder" {
            let source = finderDragSource
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
                guard let self else { return }
                guard let dest = self.finderContainerPOSIX(), !dest.isEmpty else { return }
                if dest != source {
                    self.lastFinderDest = dest
                    self.lastFinderAt = ProcessInfo.processInfo.systemUptime
                    self.lastActionTick += 1
                }
            }
        }
    }

    private func replayChord(alsoMove: Bool) {
        guard let chord = lastChord else {
            NSSound.beep()
            return
        }
        isReplaying = true
        NSWorkspace.shared.frontmostApplication?.activate(options: [])
        showHUD("Repeating \(chord.label)")
        log("post chord \(chord.label)")
        if !Self.replayChordViaSystemEvents(chord) {
            Self.postChordToPid(key: chord.keyCode, flags: chord.flags)
        }
        if alsoMove, let g = lastGesture {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.performGesture(g)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self?.isReplaying = false
                }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.isReplaying = false
            }
        }
    }

    private func replayLastGesture() {
        guard let g = lastGesture else {
            NSSound.beep()
            return
        }
        isReplaying = true
        NSWorkspace.shared.frontmostApplication?.activate(options: [])
        showHUD("Repeating move")
        performGesture(g)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.isReplaying = false
        }
    }

    private func performGesture(_ g: PointerAction) {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let start = CGEvent(source: nil)?.location ?? .zero
        let src = CGEventSource(stateID: .hidSystemState)
        let end = CGPoint(x: start.x + g.dx, y: start.y + g.dy)
        var didRelease = false
        let release = {
            guard !didRelease else { return }
            didRelease = true
            Self.postMouse(.leftMouseUp, at: end, flags: g.flags, source: src, pid: pid)
        }
        defer { release() }

        Self.postMouse(.leftMouseDown, at: start, flags: g.flags, source: src, pid: pid)
        usleep(12_000)
        let distance = hypot(g.dx, g.dy)
        let steps = distance.isFinite ? Int(min(32, max(12, distance / 6))) : 16
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: start.x + g.dx * t, y: start.y + g.dy * t)
            Self.postMouse(.leftMouseDragged, at: p, flags: g.flags, source: src, pid: pid)
            usleep(10_000)
        }
    }

    private static func postMouse(_ type: CGEventType, at point: CGPoint, flags: CGEventFlags, source: CGEventSource?, pid: pid_t) {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }
        event.flags = flags
        if pid != 0 {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    private static func replayChordViaSystemEvents(_ chord: LastChord) -> Bool {
        var using: [String] = []
        if chord.flags.contains(.maskCommand) { using.append("command down") }
        if chord.flags.contains(.maskControl) { using.append("control down") }
        if chord.flags.contains(.maskAlternate) { using.append("option down") }
        if chord.flags.contains(.maskShift) { using.append("shift down") }
        let usingClause = using.isEmpty ? "" : " using {\(using.joined(separator: ", "))}"
        let script = """
        tell application "System Events"
            key code \(Int(chord.keyCode))\(usingClause)
        end tell
        """
        return runAppleScript(script) != nil
    }

    private static func postChordToPid(key: CGKeyCode, flags: CGEventFlags) {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let src = CGEventSource(stateID: .hidSystemState)
        var mods: [(CGEventFlags, CGKeyCode)] = []
        if flags.contains(.maskControl) { mods.append((.maskControl, 0x3B)) }
        if flags.contains(.maskAlternate) { mods.append((.maskAlternate, 0x3A)) }
        if flags.contains(.maskShift) { mods.append((.maskShift, 0x38)) }
        if flags.contains(.maskCommand) { mods.append((.maskCommand, 0x37)) }

        var held: CGEventFlags = []
        for (flag, modKey) in mods {
            held.insert(flag)
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: modKey, keyDown: true) else { continue }
            down.flags = held
            if pid != 0 { down.postToPid(pid) } else { down.post(tap: .cghidEventTap) }
            usleep(8_000)
        }
        if let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
           let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) {
            down.flags = flags
            up.flags = flags
            if pid != 0 {
                down.postToPid(pid)
                usleep(12_000)
                up.postToPid(pid)
            } else {
                down.post(tap: .cghidEventTap)
                usleep(12_000)
                up.post(tap: .cghidEventTap)
            }
        }
        for (flag, modKey) in mods.reversed() {
            guard let up = CGEvent(keyboardEventSource: src, virtualKey: modKey, keyDown: false) else { continue }
            held.remove(flag)
            up.flags = held
            if pid != 0 { up.postToPid(pid) } else { up.post(tap: .cghidEventTap) }
            usleep(8_000)
        }
    }

    private func finderContainerPOSIX() -> String? {
        let script = """
        tell application "Finder"
            try
                if (count of selection) is 0 then return ""
                return POSIX path of ((container of (item 1 of selection)) as alias)
            on error
                return ""
            end try
        end tell
        """
        let path = Self.runAppleScript(script)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    private func moveFinderSelection(to dest: String) {
        let escaped = Self.escapeAppleScript(dest)
        let script = """
        tell application "Finder"
            try
                set destFolder to POSIX file "\(escaped)" as alias
                move selection to destFolder
                return "ok"
            on error
                return "fail"
            end try
        end tell
        """
        _ = Self.runAppleScript(script)
    }

    private struct FieldInfo {
        let uid: String
        let value: String
    }

    private static func focusedField() -> FieldInfo? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }

        let ax = element as! AXUIElement
        if isSecure(ax) { return nil }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(ax, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        let allowed: Set<String> = [
            "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
            "AXStaticText", "AXCell"
        ]
        // Excel cells often report as AXTextField or generic groups with a value.
        let hasValue = stringAttribute(ax, kAXValueAttribute as CFString) != nil
        if !allowed.contains(role) && !hasValue { return nil }
        if role == "AXTextArea" {
            let value = stringAttribute(ax, kAXValueAttribute as CFString) ?? ""
            // Do not treat a whole document as "last action".
            if value.count > maxLength { return nil }
        }

        let value = stringAttribute(ax, kAXValueAttribute as CFString) ?? ""
        var pid: pid_t = 0
        AXUIElementGetPid(ax, &pid)
        if pid == ProcessInfo.processInfo.processIdentifier { return nil }

        let uid = "\(pid)|\(role)|\(stringAttribute(ax, kAXDescriptionAttribute as CFString) ?? "")|\(positionKey(ax))"
        return FieldInfo(uid: uid, value: value)
    }

    private static func pidOfFocused() -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        var pid: pid_t = 0
        let ax = element as! AXUIElement
        AXUIElementGetPid(ax, &pid)
        return pid == 0 ? nil : pid
    }

    private static func isSecure(_ ax: AXUIElement) -> Bool {
        var sub: CFTypeRef?
        AXUIElementCopyAttributeValue(ax, kAXSubroleAttribute as CFString, &sub)
        let subrole = (sub as? String) ?? ""
        if subrole.contains("Secure") { return true }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(ax, kAXRoleAttribute as CFString, &role)
        return ((role as? String) ?? "").contains("Secure")
    }

    private static func stringAttribute(_ ax: AXUIElement, _ attr: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, attr, &ref) == .success else { return nil }
        if let s = ref as? String { return s }
        if let n = ref as? NSNumber { return n.stringValue }
        return nil
    }

    private static func positionKey(_ ax: AXUIElement) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXPositionAttribute as CFString, &ref) == .success,
              let ref,
              CFGetTypeID(ref) == AXValueGetTypeID() else { return "" }
        let axValue = ref as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return "" }
        // macOS reports NaN/inf positions after sleep and for some off-screen
        // fields. Int(_:) traps on those and quits the whole app.
        guard let x = Self.pixel(point.x), let y = Self.pixel(point.y) else { return "" }
        return "\(x),\(y)"
    }

    private static func pixel(_ value: CGFloat) -> Int? {
        guard value.isFinite else { return nil }
        let rounded = value.rounded()
        guard rounded >= -1_000_000, rounded <= 1_000_000 else { return nil }
        return Int(rounded)
    }

    // MARK: - Replay

    /// Type the value. Never Cmd+V — Excel would paste the last copied range.
    private func typeTextByCharacter(_ string: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for ch in string {
            postCharacter(ch, source: src)
            usleep(10_000)
        }
    }

    private func postCharacter(_ ch: Character, source: CGEventSource?) {
        if let mapped = Self.keyCode(for: ch) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: mapped.code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: mapped.code, keyDown: false) else { return }
            if mapped.shift {
                down.flags = .maskShift
                up.flags = .maskShift
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return
        }
        var units = Array(ch.utf16)
        guard !units.isEmpty,
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func keyCode(for ch: Character) -> (code: CGKeyCode, shift: Bool)? {
        switch ch {
        case "a": return (0x00, false); case "A": return (0x00, true)
        case "s": return (0x01, false); case "S": return (0x01, true)
        case "d": return (0x02, false); case "D": return (0x02, true)
        case "f": return (0x03, false); case "F": return (0x03, true)
        case "h": return (0x04, false); case "H": return (0x04, true)
        case "g": return (0x05, false); case "G": return (0x05, true)
        case "z": return (0x06, false); case "Z": return (0x06, true)
        case "x": return (0x07, false); case "X": return (0x07, true)
        case "c": return (0x08, false); case "C": return (0x08, true)
        case "v": return (0x09, false); case "V": return (0x09, true)
        case "b": return (0x0B, false); case "B": return (0x0B, true)
        case "q": return (0x0C, false); case "Q": return (0x0C, true)
        case "w": return (0x0D, false); case "W": return (0x0D, true)
        case "e": return (0x0E, false); case "E": return (0x0E, true)
        case "r": return (0x0F, false); case "R": return (0x0F, true)
        case "y": return (0x10, false); case "Y": return (0x10, true)
        case "t": return (0x11, false); case "T": return (0x11, true)
        case "1": return (0x12, false); case "!": return (0x12, true)
        case "2": return (0x13, false); case "@": return (0x13, true)
        case "3": return (0x14, false); case "#": return (0x14, true)
        case "4": return (0x15, false); case "$": return (0x15, true)
        case "6": return (0x16, false); case "^": return (0x16, true)
        case "5": return (0x17, false); case "%": return (0x17, true)
        case "=": return (0x18, false); case "+": return (0x18, true)
        case "9": return (0x19, false); case "(": return (0x19, true)
        case "7": return (0x1A, false); case "&": return (0x1A, true)
        case "-": return (0x1B, false); case "_": return (0x1B, true)
        case "8": return (0x1C, false); case "*": return (0x1C, true)
        case "0": return (0x1D, false); case ")": return (0x1D, true)
        case "]": return (0x1E, false); case "}": return (0x1E, true)
        case "o": return (0x1F, false); case "O": return (0x1F, true)
        case "u": return (0x20, false); case "U": return (0x20, true)
        case "[": return (0x21, false); case "{": return (0x21, true)
        case "i": return (0x22, false); case "I": return (0x22, true)
        case "p": return (0x23, false); case "P": return (0x23, true)
        case "l": return (0x25, false); case "L": return (0x25, true)
        case "j": return (0x26, false); case "J": return (0x26, true)
        case "'": return (0x27, false); case "\"": return (0x27, true)
        case "k": return (0x28, false); case "K": return (0x28, true)
        case ";": return (0x29, false); case ":": return (0x29, true)
        case "\\": return (0x2A, false); case "|": return (0x2A, true)
        case ",": return (0x2B, false); case "<": return (0x2B, true)
        case "/": return (0x2C, false); case "?": return (0x2C, true)
        case "n": return (0x2D, false); case "N": return (0x2D, true)
        case "m": return (0x2E, false); case "M": return (0x2E, true)
        case ".": return (0x2F, false); case ">": return (0x2F, true)
        case " ": return (0x31, false)
        case "`": return (0x32, false); case "~": return (0x32, true)
        default: return nil
        }
    }

    @discardableResult
    private func fillExcel(_ text: String) -> Bool {
        let escaped = Self.escapeAppleScript(text)
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
        return Self.runAppleScript(script) == "ok"
    }

    @discardableResult
    private func fillNumbers(_ text: String) -> Bool {
        let escaped = Self.escapeAppleScript(text)
        let script = """
        tell application "Numbers"
            try
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
        return Self.runAppleScript(script) == "ok"
    }

    private func renameFinderSelection(to raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ns = trimmed as NSString
        let capturedExt = ns.pathExtension
        let capturedBase = capturedExt.isEmpty ? trimmed : ns.deletingPathExtension
        let escapedBase = Self.escapeAppleScript(capturedBase)
        let escapedFull = Self.escapeAppleScript(trimmed)
        let keepOriginalExt = capturedExt.isEmpty

        let script = """
        tell application "Finder"
            set theItems to selection as alias list
            if (count of theItems) is 0 then return "none"
            set idx to 1
            repeat with theItem in theItems
                set origExt to name extension of theItem
                if \(keepOriginalExt ? "true" : "false") then
                    if origExt is "" then
                        set dest to "\(escapedBase)"
                    else
                        set dest to "\(escapedBase)" & "." & origExt
                    end if
                else
                    set dest to "\(escapedFull)"
                end if
                if idx > 1 then
                    set destBase to dest
                    set destExt to ""
                    if dest contains "." then
                        set AppleScript's text item delimiters to "."
                        set destExt to "." & (last text item of dest)
                        set destBase to text 1 thru -((count of destExt) + 1) of dest
                        set AppleScript's text item delimiters to ""
                    end if
                    set dest to destBase & " " & idx & destExt
                end if
                try
                    set name of theItem to dest
                end try
                set idx to idx + 1
            end repeat
            return "ok"
        end tell
        """
        _ = Self.runAppleScript(script)
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
        if let error = error {
            RepeatEngine.shared.log("applescript error \(error)")
            return nil
        }
        return result.stringValue ?? "ok"
    }

    private func log(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Redge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("repeat.log")
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: url)
        }
    }

    private func showHUD(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.hudHideWork?.cancel()
            let panel: NSPanel
            if let existing = self.hudPanel {
                panel = existing
            } else {
                panel = NSPanel(
                    contentRect: NSRect(x: 0, y: 0, width: 360, height: 44),
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                panel.level = .statusBar
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = true
                panel.ignoresMouseEvents = true
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                let label = NSTextField(labelWithString: text)
                label.font = .systemFont(ofSize: 15, weight: .semibold)
                label.textColor = .white
                label.alignment = .center
                label.translatesAutoresizingMaskIntoConstraints = true
                let box = NSView(frame: panel.contentView!.bounds)
                box.wantsLayer = true
                box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
                box.layer?.cornerRadius = 12
                box.autoresizingMask = [.width, .height]
                label.frame = box.bounds.insetBy(dx: 12, dy: 10)
                label.autoresizingMask = [.width, .height]
                box.addSubview(label)
                panel.contentView = box
                self.hudPanel = panel
            }
            if let label = panel.contentView?.subviews.compactMap({ $0 as? NSTextField }).first
                ?? panel.contentView?.subviews.first?.subviews.compactMap({ $0 as? NSTextField }).first {
                label.stringValue = text
            }
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                let p = panel.frame
                panel.setFrameOrigin(NSPoint(x: f.midX - p.width / 2, y: f.minY + 80))
            }
            panel.orderFrontRegardless()
            let work = DispatchWorkItem { [weak self] in
                self?.hudPanel?.orderOut(nil)
            }
            self.hudHideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
        }
    }
}
