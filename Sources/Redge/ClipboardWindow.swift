import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class FocusableNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ClipboardWindow {
    private let panel: FocusableNSPanel
    private let clipboardManager: ClipboardManager
    let calcState = CalculatorState()
    private(set) var isVisible = false
    private var targetFrame: NSRect = .zero
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?
    private var hostingView: NSView?

    private let windowWidth: CGFloat = 340
    private let windowHeight: CGFloat = 580
    private let edgeInset: CGFloat = 8

    init(clipboardManager: ClipboardManager) {
        self.clipboardManager = clipboardManager

        panel = FocusableNSPanel(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        weak var weakSelf: ClipboardWindow?
        let view = PanelView(
            clipboardManager: clipboardManager,
            calcState: calcState,
            onCopy: { content in weakSelf?.handleCopy(content) },
            onDelete: { item in clipboardManager.remove(item) },
            onClear: { clipboardManager.clearHistory() },
            onTogglePin: { item in clipboardManager.togglePin(item) },
            onCalculatorActive: { active in
                weakSelf?.setCalculatorKeyCapture(active)
            }
        )
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
        panel.contentView = hostingView
        self.hostingView = hostingView
        weakSelf = self
    }

    func show(on screen: NSScreen) {
        if isVisible { return }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }
        isVisible = true
        installKeyMonitor()
        if calcState.isActive {
            setCalculatorKeyCapture(true)
        }

        let frame = screen.visibleFrame
        let yPos = frame.midY - windowHeight / 2
        let fromLeft = AppSettings.shared.edgeSide == .left
        let endX = fromLeft ? frame.minX + edgeInset : frame.maxX - windowWidth - edgeInset
        let startX = fromLeft ? frame.minX - windowWidth : frame.maxX

        let endFrame = NSRect(x: endX, y: yPos, width: windowWidth, height: windowHeight)
        targetFrame = endFrame

        panel.setFrame(
            NSRect(x: startX, y: yPos, width: windowWidth, height: windowHeight),
            display: false
        )
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(endFrame, display: true)
        }
    }

    func hide() {
        if !isVisible { return }
        isVisible = false
        removeKeyMonitor()

        let currentFrame = panel.frame
        let fromLeft = AppSettings.shared.edgeSide == .left
        let endX = fromLeft
            ? currentFrame.minX - windowWidth - edgeInset - 4
            : currentFrame.minX + windowWidth + edgeInset + 4
        let endFrame = NSRect(
            x: endX, y: currentFrame.minY,
            width: windowWidth, height: windowHeight
        )

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(endFrame, display: true)
        }, completionHandler: { [weak self] in
            guard let self = self, !self.isVisible else { return }
            self.panel.orderOut(nil)
        })
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            if self.calcState.isActive && !self.calcState.converterFieldFocused {
                // Local monitors only see this app. Steal calc keys unless they
                // belong to another Redge window (Settings). Do not require the
                // panel to already be key — nonactivating panels often are not.
                let otherWindow = event.window != nil && event.window !== self.panel
                if !otherWindow, self.calcState.handleKey(event) {
                    return nil
                }
            }

            if let responder = self.panel.firstResponder {
                if responder is NSText || responder is NSTextView {
                    return event
                }
            }
            if event.keyCode == 53 { // Escape
                self.hide()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    func containsMouse(at point: NSPoint) -> Bool {
        guard isVisible else { return false }
        return NSPointInRect(point, targetFrame)
    }

    /// Calculator tab needs to be the key window so the number row and keypad
    /// type into the calc instead of the previously focused app.
    fileprivate func setCalculatorKeyCapture(_ active: Bool) {
        panel.becomesKeyOnlyIfNeeded = !active
        if active {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            calcState.converterFieldFocused = false
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.panel.makeKeyAndOrderFront(nil)
                self.panel.makeFirstResponder(self.hostingView)
                self.calcState.converterFieldFocused = false
            }
        } else {
            panel.becomesKeyOnlyIfNeeded = true
        }
    }

    private func handleCopy(_ content: ClipboardContent) {
        clipboardManager.copy(content)
        guard AutoPaste.isEnabled() else { return }
        let app = previousApp
        hide()
        AutoPaste.paste(into: app, content: content)
    }
}

struct PanelView: View {
    @ObservedObject var clipboardManager: ClipboardManager
    @ObservedObject var calcState: CalculatorState
    let onCopy: (ClipboardContent) -> Void
    let onDelete: (ClipboardItem) -> Void
    let onClear: () -> Void
    let onTogglePin: (ClipboardItem) -> Void
    let onCalculatorActive: (Bool) -> Void

    @State private var selectedTab: PanelTab = .clipboard
    @State private var isDropTarget = false

    enum PanelTab: String, CaseIterable, Hashable {
        case clipboard = "Clipboard"
        case calculator = "Calculator"
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            Group {
                if selectedTab == .clipboard {
                    ClipboardContentView(
                        clipboardManager: clipboardManager,
                        onCopy: onCopy,
                        onDelete: onDelete,
                        onClear: onClear,
                        onTogglePin: onTogglePin
                    )
                } else {
                    CalculatorView(state: calcState, onCopy: { text in
                        onCopy(.text(text))
                    }, onBecameActive: {
                        onCalculatorActive(true)
                    })
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            InfoBarView()
        }
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(strokeColor, lineWidth: strokeWidth)
        )
        .onDrop(of: [.image, .text, .fileURL, .url], isTargeted: $isDropTarget) { providers in
            handleDrop(providers: providers)
        }
        .onChange(of: selectedTab) { tab in
            let calc = tab == .calculator
            calcState.isActive = calc
            onCalculatorActive(calc)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $selectedTab) {
                ForEach(PanelTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            Button(action: { SettingsWindow.shared.show() }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Settings")
            Button(action: { clipboardManager.isFrozen.toggle() }) {
                Image(systemName: clipboardManager.isFrozen ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .rotationEffect(.degrees(clipboardManager.isFrozen ? 0 : 45))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(clipboardManager.isFrozen ? .accentColor : .secondary)
            .help(clipboardManager.isFrozen ? "Unpin (auto-hide on)" : "Pin panel open")
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 4)
    }

    private var strokeColor: Color {
        if isDropTarget { return Color.accentColor.opacity(0.85) }
        if clipboardManager.isFrozen { return Color.accentColor.opacity(0.55) }
        return Color.white.opacity(0.08)
    }

    private var strokeWidth: CGFloat {
        if isDropTarget { return 2 }
        if clipboardManager.isFrozen { return 1.5 }
        return 0.5
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        let manager = clipboardManager
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage,
                          let png = ClipboardManager.pngData(from: image) else { return }
                    DispatchQueue.main.async { manager.add(imageData: png) }
                }
                handled = true
            } else if provider.canLoadObject(ofClass: NSURL.self) {
                _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                    guard let url = object as? URL else { return }
                    let isImage = ClipboardManager.imageExtensions
                        .contains(url.pathExtension.lowercased())
                    if isImage,
                       let image = NSImage(contentsOf: url),
                       let png = ClipboardManager.pngData(from: image) {
                        DispatchQueue.main.async { manager.add(imageData: png) }
                    } else if url.isFileURL {
                        DispatchQueue.main.async { manager.add(filePath: url.path) }
                    } else {
                        DispatchQueue.main.async { manager.add(text: url.absoluteString) }
                    }
                }
                handled = true
            } else if provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let s = object as? String, !s.isEmpty else { return }
                    DispatchQueue.main.async { manager.add(text: s) }
                }
                handled = true
            }
        }
        return handled
    }
}

struct ClipboardContentView: View {
    @ObservedObject var clipboardManager: ClipboardManager
    let onCopy: (ClipboardContent) -> Void
    let onDelete: (ClipboardItem) -> Void
    let onClear: () -> Void
    let onTogglePin: (ClipboardItem) -> Void
    @FocusState private var isSearchFocused: Bool
    @State private var subTab: SubTab = .temp
    @State private var isAddingNote = false
    @State private var newNoteText = ""
    @State private var departingItemId: UUID?
    @State private var highlightNoteId: UUID?
    @State private var notesTabPulse = false

    enum SubTab: String, CaseIterable, Hashable {
        case temp = "Temp"
        case notes = "Notes"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            subTabBar
            searchBar
            Divider()
            Group {
                if subTab == .temp {
                    tempContentArea
                } else {
                    notesContentArea
                }
            }
        }
        .onChange(of: clipboardManager.searchFocusRequest) { _ in
            isSearchFocused = true
        }
    }

    private var subTabBar: some View {
        HStack(spacing: 0) {
            ForEach(SubTab.allCases, id: \.self) { tab in
                subTabButton(tab)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private func subTabButton(_ tab: SubTab) -> some View {
        let active = subTab == tab
        let count = tab == .temp ? clipboardManager.history.count : clipboardManager.notes.count
        let pulsing = tab == .notes && notesTabPulse
        return Button(action: { subTab = tab }) {
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    if pulsing {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.accentColor)
                            .transition(.scale.combined(with: .opacity))
                    }
                    Text(tab.rawValue)
                        .font(.system(size: 11, weight: active ? .semibold : .regular))
                        .foregroundColor(active ? .primary : .secondary)
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.75))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(active ? 0.10 : 0.05))
                            .clipShape(Capsule())
                    }
                }
                Rectangle()
                    .fill(active ? Color.accentColor : Color.clear)
                    .frame(height: 1.5)
            }
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .scaleEffect(pulsing ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: pulsing)
    }

    private func moveItemToNotes(_ item: ClipboardItem) {
        guard departingItemId == nil else { return }
        withAnimation(.easeInOut(duration: 0.42)) {
            departingItemId = item.id
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            withAnimation(.easeInOut(duration: 0.3)) {
                guard let note = clipboardManager.moveItemToNotes(item) else {
                    departingItemId = nil
                    return
                }
                departingItemId = nil
                highlightNoteId = note.id
                subTab = .notes
                notesTabPulse = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                withAnimation(.easeOut(duration: 0.25)) { notesTabPulse = false }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeOut(duration: 0.4)) { highlightNoteId = nil }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            TextField(subTab == .temp ? "Search clipboard…" : "Search notes…",
                      text: $clipboardManager.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isSearchFocused)
            if !clipboardManager.searchQuery.isEmpty {
                Button(action: { clipboardManager.searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            if subTab == .notes {
                Button(action: {
                    newNoteText = ""
                    isAddingNote = true
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .help("Add note")
                .disabled(isAddingNote)
            }
            if subTab == .temp && !clipboardManager.history.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Temp (keeps pinned + Notes)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var tempContentArea: some View {
        if clipboardManager.history.isEmpty {
            emptyView(
                icon: "doc.on.clipboard",
                title: "Nothing copied yet",
                subtitle: "Copy text or images — they appear here instantly"
            )
        } else if clipboardManager.filteredHistory.isEmpty {
            emptyView(
                icon: "magnifyingglass",
                title: "No matches",
                subtitle: "Try a different search"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    if !clipboardManager.recentFills.isEmpty {
                        recentFillsStrip
                    }
                    ForEach(clipboardManager.filteredHistory) { item in
                        ClipboardRow(
                            item: item,
                            searchQuery: clipboardManager.searchQuery,
                            isDeparting: departingItemId == item.id,
                            onTap: { onCopy(item.content) },
                            onDelete: { onDelete(item) },
                            onTogglePin: { onTogglePin(item) },
                            onSaveToNotes: { moveItemToNotes(item) },
                            onUseText: { text in
                                clipboardManager.add(text: text)
                                onCopy(.text(text))
                            }
                        )
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity.combined(with: .move(edge: .trailing))
                        ))
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .animation(.easeInOut(duration: 0.35), value: clipboardManager.filteredHistory.map(\.id))
            }
        }
    }

    @ViewBuilder
    private var notesContentArea: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                if isAddingNote {
                    InlineNoteEditor(
                        title: "New Note",
                        initialTitle: "",
                        initialText: newNoteText,
                        onSave: { noteTitle, saved in
                            clipboardManager.addNote(text: saved, title: noteTitle)
                            newNoteText = ""
                            isAddingNote = false
                        },
                        onCancel: {
                            newNoteText = ""
                            isAddingNote = false
                        }
                    )
                }
                if clipboardManager.notes.isEmpty && !isAddingNote {
                    emptyView(
                        icon: "note.text",
                        title: "No notes yet",
                        subtitle: "Tap + to write one, or bookmark a Temp row to move it here. Notes stay forever — Clear Temp never touches them."
                    )
                    .frame(minHeight: 320)
                } else if !clipboardManager.notes.isEmpty && clipboardManager.filteredNotes.isEmpty && !isAddingNote {
                    emptyView(
                        icon: "magnifyingglass",
                        title: "No matches",
                        subtitle: "Try a different search"
                    )
                    .frame(minHeight: 240)
                } else {
                    ForEach(clipboardManager.filteredNotes) { note in
                        NoteRow(
                            note: note,
                            searchQuery: clipboardManager.searchQuery,
                            isHighlighted: highlightNoteId == note.id,
                            onTap: { onCopy(.text(note.text)) },
                            onSave: { noteTitle, newText in
                                clipboardManager.updateNote(id: note.id, text: newText, title: noteTitle)
                            },
                            onDelete: {
                                clipboardManager.deleteNote(id: note.id)
                            }
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .animation(.easeInOut(duration: 0.35), value: clipboardManager.filteredNotes.map(\.id))
        }
    }

    private var recentFillsStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent fills")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(clipboardManager.recentFills, id: \.self) { fill in
                        Button {
                            onCopy(.text(fill))
                        } label: {
                            Text(fill)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(fill)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    private func emptyView(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(.secondary.opacity(0.6))
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private enum CopyTimeFormat {
    static func label(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        let day = calendar.component(.day, from: date)
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMM"
        let month = monthFormatter.string(from: date)
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return "\(day)\(ordinalSuffix(day)) \(month)"
        }
        return "\(day)\(ordinalSuffix(day)) \(month) \(calendar.component(.year, from: date))"
    }

    private static func ordinalSuffix(_ day: Int) -> String {
        switch day {
        case 11...13: return "th"
        default:
            switch day % 10 {
            case 1: return "st"
            case 2: return "nd"
            case 3: return "rd"
            default: return "th"
            }
        }
    }
}

private func imageSizeLabel(_ size: NSSize) -> String {
    guard size.width.isFinite, size.height.isFinite,
          size.width >= 0, size.height >= 0,
          size.width < 1_000_000, size.height < 1_000_000 else {
        return "—"
    }
    return "\(Int(size.width.rounded()))×\(Int(size.height.rounded()))"
}

private func highlightedText(_ text: String, query: String) -> Text {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return Text(text) }
    var result = Text("")
    var remainder = text[...]
    while let range = remainder.range(of: q, options: .caseInsensitive) {
        result = result + Text(String(remainder[..<range.lowerBound]))
        result = result + Text(String(remainder[range])).foregroundColor(.accentColor).fontWeight(.semibold)
        remainder = remainder[range.upperBound...]
    }
    return result + Text(String(remainder))
}

struct ClipboardRow: View {
    let item: ClipboardItem
    let searchQuery: String
    let isDeparting: Bool
    let onTap: () -> Void
    let onDelete: () -> Void
    let onTogglePin: () -> Void
    let onSaveToNotes: () -> Void
    var onUseText: (String) -> Void = { _ in }
    @State private var isHovered = false
    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            contentView
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { handleTap() }

            trailingColumn
                .frame(minWidth: trailingColumnMinWidth, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(rowBackground)
        .overlay(departingOverlay)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .offset(x: isDeparting ? 52 : 0, y: isDeparting ? -6 : 0)
        .scaleEffect(isDeparting ? 0.9 : 1, anchor: .leading)
        .opacity(isDeparting ? 0 : 1)
        .animation(.easeInOut(duration: 0.42), value: isDeparting)
        .onDrag(dragProvider)
        .contextMenu { transformMenu }
        .onHover { hovering in
            if !isDeparting { isHovered = hovering }
        }
        .allowsHitTesting(!isDeparting)
    }

    @ViewBuilder
    private var transformMenu: some View {
        if case .text(let text) = item.content {
            Button("Trim") { onUseText(TextTools.trim(text)) }
            Button("UPPERCASE") { onUseText(TextTools.upper(text)) }
            Button("lowercase") { onUseText(TextTools.lower(text)) }
            Button("Extract numbers") { onUseText(TextTools.extractNumbers(text)) }
            Button("Split tabs / columns") { onUseText(TextTools.splitTabs(text)) }
            Divider()
        }
        Button("Copy") { handleTap() }
        if canSaveToNotes {
            Button("Move to Notes") { onSaveToNotes() }
        }
        Button(item.isPinned ? "Unpin" : "Pin") { onTogglePin() }
        Button("Delete") { onDelete() }
    }

    private var rowBackground: Color {
        if isDeparting { return Color.accentColor.opacity(0.14) }
        return isHovered ? Color.white.opacity(0.12) : .clear
    }

    @ViewBuilder
    private var departingOverlay: some View {
        if isDeparting {
            HStack(spacing: 4) {
                Image(systemName: "note.text")
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.accentColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .padding(.trailing, 12)
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
        }
    }

    @ViewBuilder
    private var trailingColumn: some View {
        if isHovered && !didCopy {
            HStack(spacing: 2) {
                if let url = urlIfPresent {
                    HoverIconButton(
                        systemName: "arrow.up.right.square",
                        help: url.isFileURL ? "Open" : "Open URL"
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                }
                if canSaveToNotes {
                    HoverIconButton(
                        systemName: "bookmark.fill",
                        help: "Move to Notes",
                        color: .accentColor
                    ) {
                        onSaveToNotes()
                    }
                }
                HoverIconButton(
                    systemName: item.isPinned ? "pin.slash.fill" : "pin.fill",
                    help: item.isPinned ? "Unpin" : "Pin",
                    rotation: item.isPinned ? 0 : 45,
                    color: item.isPinned ? .accentColor : .secondary
                ) { onTogglePin() }
                HoverIconButton(systemName: "xmark.circle.fill", help: "Delete") {
                    onDelete()
                }
            }
            .padding(.top, 1)
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                if !didCopy && item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .rotationEffect(.degrees(-25))
                        .foregroundColor(.accentColor)
                }
                if didCopy {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.green)
                } else {
                    Text(CopyTimeFormat.label(for: item.date))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.secondary.opacity(0.9))
                        .fixedSize()
                }
            }
            .padding(.top, 1)
        }
    }

    private var canSaveToNotes: Bool {
        switch item.content {
        case .text(let text):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .file(let path):
            return !path.isEmpty
        case .image:
            return !(item.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    private var trailingColumnMinWidth: CGFloat {
        if isHovered && !didCopy { return hoverButtonsWidth }
        return 36
    }

    private var hoverButtonsWidth: CGFloat {
        var w: CGFloat = 44  // pin + delete
        if canSaveToNotes { w += 22 }
        if urlIfPresent != nil { w += 22 }
        return w
    }

    private var urlIfPresent: URL? {
        switch item.content {
        case .text(let text) where text.isLikelyURL:
            return text.firstURL
        case .file(let path):
            return URL(fileURLWithPath: path)
        default:
            return nil
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch item.content {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            HStack(alignment: .top, spacing: 6) {
                if let color = TextTools.hexColor(from: text) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: 12, height: 12)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                        .padding(.top, 2)
                } else if text.isLikelyURL {
                    Image(systemName: "globe")
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                        .padding(.top, 1)
                }
                highlightedText(trimmed.isEmpty ? text : trimmed, query: searchQuery)
                    .lineLimit(3)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
            }
            .help(text)
        case .file(let path):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "doc")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    highlightedText(URL(fileURLWithPath: path).lastPathComponent, query: searchQuery)
                        .font(.system(size: 12, weight: .medium))
                    Text(path)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .help(path)
        case .image(let data):
            if let nsImage = NSImage(data: data) {
                HStack(spacing: 10) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 56, height: 56)
                        .background(Color.black.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("Image")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.primary)
                            if let ocr = item.ocrText, !ocr.isEmpty {
                                Image(systemName: "text.viewfinder")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .help("Text recognized")
                            }
                        }
                        Text(imageSizeLabel(nsImage.size))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        if let snippet = ocrSnippet {
                            highlightedText(snippet, query: searchQuery)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary.opacity(0.85))
                                .lineLimit(2)
                        }
                    }
                }
                .help(item.ocrText ?? "")
            } else {
                Text("(image)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var ocrSnippet: String? {
        guard let raw = item.ocrText, !raw.isEmpty else { return nil }
        let cleaned = raw.replacingOccurrences(of: "\n", with: " ")
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty,
           let range = cleaned.range(of: q, options: .caseInsensitive) {
            let radius = 30
            let lower = cleaned.index(range.lowerBound, offsetBy: -radius, limitedBy: cleaned.startIndex) ?? cleaned.startIndex
            let upper = cleaned.index(range.upperBound, offsetBy: radius, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
            var snippet = String(cleaned[lower..<upper])
            if lower != cleaned.startIndex { snippet = "…" + snippet }
            if upper != cleaned.endIndex { snippet += "…" }
            return snippet
        }
        return String(cleaned.prefix(80))
    }

    private func dragProvider() -> NSItemProvider {
        switch item.content {
        case .text(let text):
            return NSItemProvider(object: text as NSString)
        case .file(let path):
            return NSItemProvider(contentsOf: URL(fileURLWithPath: path)) ?? NSItemProvider()
        case .image(let data):
            if let image = NSImage(data: data) {
                return NSItemProvider(object: image)
            }
            return NSItemProvider()
        }
    }

    private func handleTap() {
        onTap()
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            didCopy = false
        }
    }
}

struct HoverIconButton: View {
    let systemName: String
    let help: String
    var rotation: Double = 0
    var color: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundColor(color)
                .rotationEffect(.degrees(rotation))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct NoteRow: View {
    let note: Note
    let searchQuery: String
    let isHighlighted: Bool
    let onTap: () -> Void
    let onSave: (String?, String) -> Void
    let onDelete: () -> Void
    @State private var isHovered = false
    @State private var didCopy = false
    @State private var isEditing = false

    var body: some View {
        if isEditing {
            InlineNoteEditor(
                title: "Edit Note",
                initialTitle: note.title ?? "",
                initialText: note.text,
                onSave: { noteTitle, saved in
                    onSave(noteTitle, saved)
                    isEditing = false
                },
                onCancel: { isEditing = false }
            )
        } else {
            displayRow
        }
    }

    private var displayRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "note.text")
                .font(.system(size: 11))
                .foregroundColor(.accentColor.opacity(0.85))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                if let title = note.title, !title.isEmpty {
                    highlightedText(title, query: searchQuery)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                }
                highlightedText(displayedText, query: searchQuery)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    onTap()
                    didCopy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { didCopy = false }
                }

            if isHovered && !didCopy {
                HStack(spacing: 2) {
                    HoverIconButton(systemName: "pencil", help: "Edit") {
                        isEditing = true
                    }
                    HoverIconButton(systemName: "xmark.circle.fill", help: "Delete") {
                        onDelete()
                    }
                }
                .padding(.top, 1)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    if didCopy {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.green)
                    } else {
                        Text(CopyTimeFormat.label(for: note.updatedAt))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(.secondary.opacity(0.9))
                            .fixedSize()
                    }
                }
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(noteRowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isHighlighted ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .help(note.text)
        .animation(.easeInOut(duration: 0.35), value: isHighlighted)
        .onHover { hovering in isHovered = hovering }
    }

    private var displayedText: String {
        let trimmed = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? note.text : trimmed
    }

    private var noteRowBackground: Color {
        if isHighlighted { return Color.accentColor.opacity(0.2) }
        if isHovered { return Color.white.opacity(0.12) }
        return .clear
    }
}

/// Inline editor that lives inside the panel itself (not in a popover).
/// Popovers anchored on a non-activating panel have known SwiftUI issues
/// where TextEditor accepts typing but ⌘V paste falls through. Inline avoids
/// that whole class of bug because the panel handles keys correctly.
struct InlineNoteEditor: View {
    let title: String
    let initialTitle: String
    let initialText: String
    let onSave: (String?, String) -> Void
    let onCancel: () -> Void

    @State private var noteTitle: String = ""
    @State private var text: String = ""
    @FocusState private var editorFocused: Bool

    init(title: String, initialTitle: String = "", initialText: String,
         onSave: @escaping (String?, String) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.initialTitle = initialTitle
        self.initialText = initialText
        self.onSave = onSave
        self.onCancel = onCancel
        _noteTitle = State(initialValue: initialTitle)
        _text = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "note.text")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }
            TextField("Title (optional)", text: $noteTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .padding(6)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            TextEditor(text: $text)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(minHeight: 90, maxHeight: 220)
                .focused($editorFocused)
            HStack {
                Text("⌘↩ to save · esc to cancel")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.7))
                Spacer()
                Text("\(text.count)")
                    .font(.system(size: 9, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.secondary.opacity(0.55))
                Button("Cancel", action: onCancel)
                    .controlSize(.small)
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Save") { onSave(noteTitle, text) }
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                editorFocused = true
            }
        }
    }
}

struct InfoBarView: View {
    @State private var showInfo = false
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var repeater = RepeatEngine.shared

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { showInfo.toggle() }) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Features")
            .popover(isPresented: $showInfo, arrowEdge: .top) {
                InfoView().frame(width: 300)
            }
            Button(action: { SettingsWindow.shared.show() }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
            Text(appVersionLabel)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundColor(.secondary.opacity(0.55))
                .help("Redge \(appVersionLabel)")
            if repeater.isEnabled {
                Text(repeatStatus)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundColor(repeatStatusColor)
                    .lineLimit(1)
                    .help("Repeat last typed value or last duplicate/move")
            }
            Spacer()
            Toggle(isOn: $settings.autoPasteEnabled) {
                Text("Auto-paste")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .onChange(of: settings.autoPasteEnabled) { newValue in
                if newValue && !AutoPaste.isAccessibilityTrusted {
                    AutoPaste.requestAccessibility()
                }
            }
            .help("Fill the selected cell or paste on click (needs Accessibility)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var appVersionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "v\(version ?? "2.1")"
    }

    private var repeatStatus: String {
        let key = AppSettings.shared.repeatHotkeyLabel
        if !repeater.accessibilityReady { return "Turn on Accessibility" }
        if !repeater.captureReady { return "Turn on Input Monitoring" }
        if repeater.preview.isEmpty { return key }
        return "\(key) \(repeater.preview)"
    }

    private var repeatStatusColor: Color {
        if !repeater.accessibilityReady || !repeater.captureReady {
            return .orange.opacity(0.9)
        }
        return .secondary.opacity(0.7)
    }
}

struct InfoView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Redge — Clipboard, Calculator & Repeat")
                .font(.system(size: 13, weight: .semibold))
            Divider()
            featureRow("gearshape", "Settings: edge side, hotkeys, history size, Auto-paste, Repeat, notes export")
            featureRow("arrow.uturn.left", "Repeat is off until you enable it. Then it replays the last shortcut, move, or Finder drop")
            featureRow("folder", "Finder: rename another selected file to the last name (keeps extension)")
            featureRow("tablecells", "Excel / Numbers: click a clip to fill the selected cell when Auto-paste is on")
            featureRow("rectangle.righthalf.filled", "Slide the cursor into the configured screen edge to open")
            featureRow("keyboard", "Panel and Repeat shortcuts are customizable in Settings")
            featureRow("textformat", "Right-click a text clip to trim, change case, extract numbers, or split columns")
            featureRow("clock", "Recent fills sit above Temp so you can reuse the last pasted values")
            featureRow("magnifyingglass", "Search across text and image OCR (auto-focused on hotkey)")
            featureRow("note.text", "Notes sub-tab: persistent text snippets, never wiped by Clear Temp")
            featureRow("bookmark", "Bookmark on a Temp row moves it to Notes (removed from Temp)")
            featureRow("pin.fill", "Pin items so they survive Clear and never expire")
            featureRow("text.viewfinder", "Images get OCR'd in the background — search inside screenshots")
            featureRow("hand.draw", "Drag images and text in/out of the panel")
            featureRow("function", "Calculator: number keys type into the pad. C clears the current number; AC clears the sum. ⌫ deletes the last digit.")
            featureRow("lock.shield", "Passwords from password managers are skipped automatically")
            featureRow("hand.tap", "Auto-paste on click (toggle below — needs Accessibility)")
            featureRow("escape", "Esc closes the panel (when you are not typing)")
            featureRow("camera", "Screenshot mode: stays hidden, or freezes if already open")
            featureRow("power", "Launch at Login from the menu-bar icon")
        }
        .padding(12)
    }

    private func featureRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
