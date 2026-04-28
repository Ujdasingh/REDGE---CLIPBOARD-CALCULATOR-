import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class FocusableNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class ClipboardWindow {
    private let panel: FocusableNSPanel
    private let clipboardManager: ClipboardManager
    let calcState = CalculatorState()
    private(set) var isVisible = false
    private var targetFrame: NSRect = .zero
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?

    private let windowWidth: CGFloat = 320
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
            onTogglePin: { item in clipboardManager.togglePin(item) }
        )
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
        panel.contentView = hostingView
        weakSelf = self
    }

    func show(on screen: NSScreen) {
        if isVisible { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        isVisible = true
        installKeyMonitor()

        let frame = screen.visibleFrame
        let yPos = frame.midY - windowHeight / 2
        let endX = frame.maxX - windowWidth - edgeInset
        let startX = frame.maxX

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
        let endX = currentFrame.minX + windowWidth + edgeInset + 4
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
            // Only handle keys when our panel is the key window — otherwise the
            // user is in another app and we shouldn't grab their keystrokes.
            guard event.window === self.panel else { return event }
            // If a text field has focus (search field, converter input), let it
            // handle the key normally.
            if let responder = self.panel.firstResponder {
                if responder is NSText || responder is NSTextView {
                    return event
                }
                // Hosted SwiftUI text fields surface as NSTextView's field editor
                // — covered above. The hosting view itself is fine to intercept past.
            }
            if self.calcState.handleKey(event) {
                return nil  // consume — don't beep
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

    private func handleCopy(_ content: ClipboardContent) {
        clipboardManager.copy(content)
        if AutoPaste.isEnabled() {
            let app = previousApp
            hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                AutoPaste.paste(into: app)
            }
        }
    }
}

struct PanelView: View {
    @ObservedObject var clipboardManager: ClipboardManager
    @ObservedObject var calcState: CalculatorState
    let onCopy: (ClipboardContent) -> Void
    let onDelete: (ClipboardItem) -> Void
    let onClear: () -> Void
    let onTogglePin: (ClipboardItem) -> Void

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
            .frame(maxWidth: .infinity)
            Button(action: { clipboardManager.isFrozen.toggle() }) {
                Image(systemName: clipboardManager.isFrozen ? "pin.fill" : "pin")
                    .font(.system(size: 12))
                    .rotationEffect(.degrees(clipboardManager.isFrozen ? 0 : 45))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(clipboardManager.isFrozen ? .accentColor : .secondary)
            .help(clipboardManager.isFrozen ? "Unpin (auto-hide on)" : "Pin panel open")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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
                    } else {
                        DispatchQueue.main.async { manager.add(text: url.path) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBar
            Divider()
            contentArea
        }
        .onChange(of: clipboardManager.searchFocusRequest) { _ in
            isSearchFocused = true
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            TextField("Search text and image content…", text: $clipboardManager.searchQuery)
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
            if !clipboardManager.history.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear history (keeps pinned)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var contentArea: some View {
        if clipboardManager.history.isEmpty {
            emptyView(
                icon: "doc.on.clipboard",
                title: "Nothing copied yet",
                subtitle: "Copy or drop text and images here"
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
                    ForEach(clipboardManager.filteredHistory) { item in
                        ClipboardRow(
                            item: item,
                            searchQuery: clipboardManager.searchQuery,
                            onTap: { onCopy(item.content) },
                            onDelete: { onDelete(item) },
                            onTogglePin: { onTogglePin(item) }
                        )
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
            }
        }
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

struct ClipboardRow: View {
    let item: ClipboardItem
    let searchQuery: String
    let onTap: () -> Void
    let onDelete: () -> Void
    let onTogglePin: () -> Void
    @State private var isHovered = false
    @State private var didCopy = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(alignment: .top, spacing: 8) {
                contentView
                    .frame(maxWidth: .infinity, alignment: .leading)
                if didCopy {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.green)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .padding(.trailing, isHovered && !didCopy ? hoverButtonsWidth : 0)
            .background(isHovered ? Color.white.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onDrag(dragProvider)
            .onTapGesture { handleTap() }

            if !isHovered && !didCopy && item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .rotationEffect(.degrees(-25))
                    .foregroundColor(.accentColor)
                    .padding(.top, 6)
                    .padding(.trailing, 8)
            }

            if isHovered && !didCopy {
                HStack(spacing: 2) {
                    if let url = urlIfPresent {
                        HoverIconButton(systemName: "arrow.up.right.square", help: "Open URL") {
                            NSWorkspace.shared.open(url)
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
                .padding(.top, 4)
                .padding(.trailing, 4)
            }
        }
        .onHover { hovering in isHovered = hovering }
    }

    private var hoverButtonsWidth: CGFloat {
        urlIfPresent != nil ? 64 : 44
    }

    private var urlIfPresent: URL? {
        if case .text(let text) = item.content, text.isLikelyURL {
            return text.firstURL
        }
        return nil
    }

    @ViewBuilder
    private var contentView: some View {
        switch item.content {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            HStack(alignment: .top, spacing: 6) {
                if text.isLikelyURL {
                    Image(systemName: "globe")
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                        .padding(.top, 1)
                }
                Text(trimmed.isEmpty ? text : trimmed)
                    .lineLimit(3)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
            }
            .help(text)
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
                        Text("\(Int(nsImage.size.width))×\(Int(nsImage.size.height))")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        if let snippet = ocrSnippet {
                            Text(snippet)
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

struct InfoBarView: View {
    @State private var showInfo = false
    @AppStorage("autoPasteEnabled") private var autoPasteEnabled: Bool = false

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
                InfoView().frame(width: 290)
            }
            Spacer()
            Toggle(isOn: $autoPasteEnabled) {
                Text("Auto-paste")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .onChange(of: autoPasteEnabled) { newValue in
                if newValue && !AutoPaste.isAccessibilityTrusted {
                    AutoPaste.requestAccessibility()
                }
            }
            .help("Auto-paste into the previous app on click (requires Accessibility permission)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

struct InfoView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Redge — Clipboard & Calculator")
                .font(.system(size: 13, weight: .semibold))
            Divider()
            featureRow("rectangle.righthalf.filled", "Slam cursor into the right edge (vertical center) to open")
            featureRow("keyboard", "⌃⌘V toggles the panel from anywhere")
            featureRow("magnifyingglass", "Search across text and image OCR (auto-focused on hotkey)")
            featureRow("pin.fill", "Pin items so they survive Clear and never expire")
            featureRow("text.viewfinder", "Images get OCR'd in the background — search inside screenshots")
            featureRow("hand.draw", "Drag images and text in/out of the panel")
            featureRow("function", "Calculator + length / weight / temperature / storage converter")
            featureRow("lock.shield", "Passwords from password managers are skipped automatically")
            featureRow("hand.tap", "Auto-paste on click (toggle below — needs Accessibility)")
            featureRow("arrow.clockwise", "History persists across restarts")
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
