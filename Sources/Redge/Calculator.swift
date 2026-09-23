import SwiftUI

final class CalculatorState: ObservableObject {
    @Published var display: String = "0"
    @Published var expression: String = ""
    @Published var history: [HistoryEntry] = []

    /// True when the Calculator tab is currently visible. Used by the panel's
    /// key-monitor to know whether to route digit/operator keypresses here.
    var isActive: Bool = false
    /// True while the unit-converter value field is focused — number keys
    /// should type into that field instead of the calculator.
    var converterFieldFocused: Bool = false

    private var lastNumber: Double = 0
    private var pendingOp: Op? = nil
    private var clearOnNext: Bool = false
    private var wasEquals: Bool = false

    @Published var convCategory: ConverterView.ConvCategory = .length
    @Published var convFromValue: String = "1"
    @Published var convFromUnit: ConverterView.ConvUnit = .meter
    @Published var convToUnit: ConverterView.ConvUnit = .foot

    static let maxHistory = 20

    struct HistoryEntry: Identifiable, Equatable {
        let id = UUID()
        let expression: String
        let result: String
    }

    enum Op {
        case add, sub, mul, div
        var symbol: String {
            switch self {
            case .add: return "+"
            case .sub: return "−"
            case .mul: return "×"
            case .div: return "÷"
            }
        }
        func apply(_ a: Double, _ b: Double) -> Double {
            switch self {
            case .add: return a + b
            case .sub: return a - b
            case .mul: return a * b
            case .div: return b == 0 ? .infinity : a / b
            }
        }
    }

    func input(_ digit: String) {
        converterFieldFocused = false
        if wasEquals {
            expression = ""
            display = "0"
            wasEquals = false
            clearOnNext = true
        }
        if clearOnNext || display == "0" {
            display = (digit == ".") ? "0." : digit
            clearOnNext = false
            return
        }
        if digit == "." && display.contains(".") { return }
        display += digit
    }

    func setOp(_ o: Op) {
        converterFieldFocused = false
        if wasEquals {
            expression = "\(display) \(o.symbol)"
            lastNumber = currentValue()
            pendingOp = o
            clearOnNext = true
            wasEquals = false
            return
        }
        if let pending = pendingOp, !clearOnNext {
            let result = pending.apply(lastNumber, currentValue())
            expression += " \(display) \(o.symbol)"
            display = format(result)
            lastNumber = result
        } else {
            lastNumber = currentValue()
            if expression.isEmpty {
                expression = "\(display) \(o.symbol)"
            } else {
                expression += " \(o.symbol)"
            }
        }
        pendingOp = o
        clearOnNext = true
    }

    func equals() {
        converterFieldFocused = false
        if let pending = pendingOp {
            let result = pending.apply(lastNumber, currentValue())
            let fullExpression = expression + " " + display
            history.insert(HistoryEntry(expression: fullExpression, result: format(result)), at: 0)
            if history.count > CalculatorState.maxHistory {
                history = Array(history.prefix(CalculatorState.maxHistory))
            }
            expression = fullExpression + " ="
            display = format(result)
            lastNumber = result
        }
        pendingOp = nil
        clearOnNext = true
        wasEquals = true
    }

    func clear() {
        display = "0"
        expression = ""
        lastNumber = 0
        pendingOp = nil
        clearOnNext = false
        wasEquals = false
    }

    func toggleSign() {
        if display.hasPrefix("-") {
            display.removeFirst()
        } else if display != "0" {
            display = "-" + display
        }
    }

    /// iOS-style percent: 50% → 0.5; 200 + 10% → 20 (then = yields 220).
    func percent() {
        let value = currentValue()
        if let pending = pendingOp, pending == .add || pending == .sub {
            display = format(lastNumber * value / 100)
        } else {
            display = format(value / 100)
        }
    }

    func backspace() {
        // After an operator, display still shows the previous number until a
        // digit is typed. ⌫ should not wipe the whole sum — just start a fresh
        // current operand.
        if wasEquals {
            wasEquals = false
            clearOnNext = false
        }
        if clearOnNext {
            display = "0"
            clearOnNext = false
            return
        }
        if display.count > 1 {
            display.removeLast()
            if display == "-" { display = "0" }
        } else {
            display = "0"
        }
    }

    /// iOS-style C / AC: first tap clears the current number, second tap clears the sum.
    func tapClear() {
        converterFieldFocused = false
        if display != "0" {
            display = "0"
            wasEquals = false
            if pendingOp != nil { clearOnNext = true }
            return
        }
        clear()
    }

    var clearButtonTitle: String { display != "0" ? "C" : "AC" }

    func recall(_ entry: HistoryEntry) {
        display = entry.result
        expression = ""
        lastNumber = Double(entry.result) ?? 0
        pendingOp = nil
        clearOnNext = true
        wasEquals = true
    }

    func clearHistory() {
        history.removeAll()
    }

    /// Routes a keyboard event to the calculator. Returns true if consumed.
    func handleKey(_ event: NSEvent) -> Bool {
        guard isActive, !converterFieldFocused else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) || mods.contains(.control) || mods.contains(.option) {
            return false
        }

        let shifted = mods.contains(.shift)
        let chars = event.characters ?? ""

        // Use the glyph the key actually produced. Shift+= is "+", not "=";
        // Shift+8 is "*", not "8". charactersIgnoringModifiers got this wrong.
        if chars.contains(where: { "+＋".contains($0) }) {
            setOp(.add)
            return true
        }
        if chars.contains(where: { "*×xX".contains($0) }) {
            setOp(.mul)
            return true
        }
        if chars.contains(where: { "/÷".contains($0) }) {
            setOp(.div)
            return true
        }
        if chars.contains(where: { "-−–—".contains($0) }) {
            setOp(.sub)
            return true
        }
        if chars.contains(where: { "%％".contains($0) }) {
            percent()
            return true
        }
        if chars.contains(where: { "=＝".contains($0) }) {
            equals()
            return true
        }
        if chars.contains(".") || chars.contains(",") {
            input(".")
            return true
        }
        if let digit = chars.first, digit.isNumber, chars.count == 1 {
            input(String(digit))
            return true
        }

        // Numpad and keys that send empty `characters` on some layouts.
        switch event.keyCode {
        case 82: input("0"); return true
        case 83: input("1"); return true
        case 84: input("2"); return true
        case 85: input("3"); return true
        case 86: input("4"); return true
        case 87: input("5"); return true
        case 88: input("6"); return true
        case 89: input("7"); return true
        case 91: input("8"); return true
        case 92: input("9"); return true
        case 65: input("."); return true
        case 67: setOp(.mul); return true
        case 69: setOp(.add); return true
        case 75: setOp(.div); return true
        case 78: setOp(.sub); return true
        case 81, 36, 76: equals(); return true
        case 71: tapClear(); return true
        case 51: backspace(); return true
        case 53: clear(); return true
        default: break
        }

        if shifted {
            switch event.keyCode {
            case 24: setOp(.add); return true   // Shift+=
            case 28: setOp(.mul); return true   // Shift+8
            default: return false
            }
        }

        switch event.keyCode {
        case 29: input("0"); return true
        case 18: input("1"); return true
        case 19: input("2"); return true
        case 20: input("3"); return true
        case 21: input("4"); return true
        case 23: input("5"); return true
        case 22: input("6"); return true
        case 26: input("7"); return true
        case 28: input("8"); return true
        case 25: input("9"); return true
        case 47: input("."); return true
        case 24: equals(); return true
        case 27: setOp(.sub); return true
        case 44: setOp(.div); return true
        default:
            return false
        }
    }

    private func currentValue() -> Double { Double(display) ?? 0 }

    private func format(_ d: Double) -> String {
        if !d.isFinite { return "Error" }
        if d == d.rounded() && abs(d) < 1e15 {
            return String(format: "%g", d)
        }
        return String(d)
    }
}

struct CalculatorView: View {
    @ObservedObject var state: CalculatorState
    @State private var didCopy = false
    let onCopy: (String) -> Void
    var onBecameActive: () -> Void = {}

    var body: some View {
        VStack(spacing: 6) {
            historyView
            expressionView
            displayView
            buttonsGrid
            Divider().padding(.vertical, 2)
            ConverterView(state: state)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .onAppear {
            state.isActive = true
            state.converterFieldFocused = false
            onBecameActive()
        }
        .onDisappear {
            state.isActive = false
            state.converterFieldFocused = false
        }
    }

    @ViewBuilder
    private var historyView: some View {
        if state.history.isEmpty {
            EmptyView()
        } else {
            ScrollView {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(state.history) { entry in
                        HistoryRow(entry: entry, onTap: {
                            state.recall(entry)
                            onCopy(entry.result)
                        })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(maxHeight: 72)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                HStack {
                    Spacer()
                    Button(action: { state.clearHistory() }) {
                        Image(systemName: "trash")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.7))
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                    .help("Clear calculation history")
                }, alignment: .topTrailing
            )
        }
    }

    private var expressionView: some View {
        HStack {
            Spacer()
            Text(state.expression.isEmpty ? " " : state.expression)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(height: 16)
        .padding(.horizontal, 12)
    }

    private var displayView: some View {
        Button(action: {
            onCopy(state.display)
            didCopy = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { didCopy = false }
        }) {
            HStack {
                if didCopy {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.green)
                }
                Spacer()
                Text(state.display)
                    .font(.system(size: 26, weight: .light, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Click to copy")
    }

    private var buttonsGrid: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                CalcButton(label: state.clearButtonTitle, kind: .fn) { state.tapClear() }
                CalcButton(label: "±", kind: .fn) { state.toggleSign() }
                CalcButton(label: "%", kind: .fn) { state.percent() }
                CalcButton(label: "÷", kind: .op) { state.setOp(.div) }
            }
            HStack(spacing: 4) {
                CalcButton(label: "7", kind: .digit) { state.input("7") }
                CalcButton(label: "8", kind: .digit) { state.input("8") }
                CalcButton(label: "9", kind: .digit) { state.input("9") }
                CalcButton(label: "×", kind: .op) { state.setOp(.mul) }
            }
            HStack(spacing: 4) {
                CalcButton(label: "4", kind: .digit) { state.input("4") }
                CalcButton(label: "5", kind: .digit) { state.input("5") }
                CalcButton(label: "6", kind: .digit) { state.input("6") }
                CalcButton(label: "−", kind: .op) { state.setOp(.sub) }
            }
            HStack(spacing: 4) {
                CalcButton(label: "1", kind: .digit) { state.input("1") }
                CalcButton(label: "2", kind: .digit) { state.input("2") }
                CalcButton(label: "3", kind: .digit) { state.input("3") }
                CalcButton(label: "+", kind: .op) { state.setOp(.add) }
            }
            HStack(spacing: 4) {
                CalcButton(label: "⌫", kind: .fn) { state.backspace() }
                CalcButton(label: "0", kind: .digit) { state.input("0") }
                CalcButton(label: ".", kind: .digit) { state.input(".") }
                CalcButton(label: "=", kind: .op) { state.equals() }
            }
        }
    }
}

struct HistoryRow: View {
    let entry: CalculatorState.HistoryEntry
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Spacer()
                Text(entry.expression)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("=")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(entry.result)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
            }
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(hovered ? Color.white.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Recall \(entry.result)")
    }
}

struct CalcButton: View {
    let label: String
    let kind: Kind
    let action: () -> Void

    enum Kind { case digit, op, fn }

    private var bgColor: Color {
        switch kind {
        case .digit: return Color.white.opacity(0.06)
        case .op: return Color.accentColor.opacity(0.85)
        case .fn: return Color.gray.opacity(0.4)
        }
    }
    private var fgColor: Color {
        switch kind {
        case .op: return .white
        default: return .primary
        }
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(fgColor)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(bgColor)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

struct ConverterView: View {
    @ObservedObject var state: CalculatorState
    @FocusState private var valueFocused: Bool

    enum ConvCategory: String, CaseIterable, Hashable {
        case length = "Length"
        case weight = "Weight"
        case temperature = "Temp"
        case storage = "Storage"
    }

    enum ConvUnit: String, CaseIterable, Hashable {
        case mm, cm, meter, km, inch, foot, yard, mile
        case mg, g, kg, oz, lb
        case celsius, fahrenheit, kelvin
        case byte, kilobyte, megabyte, gigabyte, terabyte

        var label: String {
            switch self {
            case .mm: return "mm"
            case .cm: return "cm"
            case .meter: return "m"
            case .km: return "km"
            case .inch: return "in"
            case .foot: return "ft"
            case .yard: return "yd"
            case .mile: return "mi"
            case .mg: return "mg"
            case .g: return "g"
            case .kg: return "kg"
            case .oz: return "oz"
            case .lb: return "lb"
            case .celsius: return "°C"
            case .fahrenheit: return "°F"
            case .kelvin: return "K"
            case .byte: return "B"
            case .kilobyte: return "KB"
            case .megabyte: return "MB"
            case .gigabyte: return "GB"
            case .terabyte: return "TB"
            }
        }

        var category: ConvCategory {
            switch self {
            case .mm, .cm, .meter, .km, .inch, .foot, .yard, .mile: return .length
            case .mg, .g, .kg, .oz, .lb: return .weight
            case .celsius, .fahrenheit, .kelvin: return .temperature
            case .byte, .kilobyte, .megabyte, .gigabyte, .terabyte: return .storage
            }
        }
    }

    static func unitsForCategory(_ c: ConvCategory) -> [ConvUnit] {
        ConvUnit.allCases.filter { $0.category == c }
    }

    static func convert(_ value: Double, from: ConvUnit, to: ConvUnit) -> Double {
        guard from.category == to.category else { return 0 }
        switch from.category {
        case .length:
            let m: [ConvUnit: Double] = [
                .mm: 0.001, .cm: 0.01, .meter: 1, .km: 1000,
                .inch: 0.0254, .foot: 0.3048, .yard: 0.9144, .mile: 1609.344
            ]
            return value * (m[from] ?? 1) / (m[to] ?? 1)
        case .weight:
            let g: [ConvUnit: Double] = [
                .mg: 0.001, .g: 1, .kg: 1000, .oz: 28.3495, .lb: 453.592
            ]
            return value * (g[from] ?? 1) / (g[to] ?? 1)
        case .temperature:
            var c: Double = 0
            switch from {
            case .celsius: c = value
            case .fahrenheit: c = (value - 32) * 5 / 9
            case .kelvin: c = value - 273.15
            default: break
            }
            switch to {
            case .celsius: return c
            case .fahrenheit: return c * 9 / 5 + 32
            case .kelvin: return c + 273.15
            default: return 0
            }
        case .storage:
            let b: [ConvUnit: Double] = [
                .byte: 1, .kilobyte: 1024, .megabyte: 1024*1024,
                .gigabyte: 1024*1024*1024, .terabyte: pow(1024, 4)
            ]
            return value * (b[from] ?? 1) / (b[to] ?? 1)
        }
    }

    private var convertedString: String {
        guard let v = Double(state.convFromValue) else { return "—" }
        let r = ConverterView.convert(v, from: state.convFromUnit, to: state.convToUnit)
        if !r.isFinite { return "—" }
        let absVal = abs(r)
        if absVal != 0, absVal < 0.0001 || absVal > 1e9 {
            return String(format: "%.4e", r)
        }
        if r == r.rounded() {
            return String(format: "%.0f", r)
        }
        return String(format: "%.4f", r).trimmingTrailingZeros()
    }

    var body: some View {
        VStack(spacing: 6) {
            Picker("", selection: $state.convCategory) {
                ForEach(ConvCategory.allCases, id: \.self) { c in
                    Text(c.rawValue).tag(c)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: state.convCategory) { newCat in
                let units = ConverterView.unitsForCategory(newCat)
                state.convFromUnit = units.first ?? .meter
                state.convToUnit = units.dropFirst().first ?? state.convFromUnit
            }

            HStack(spacing: 6) {
                TextField("Value", text: $state.convFromValue)
                    .textFieldStyle(.plain)
                    .focused($valueFocused)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .onChange(of: valueFocused) { focused in
                        state.converterFieldFocused = focused
                    }
                    .onAppear { valueFocused = false }
                Picker("", selection: $state.convFromUnit) {
                    ForEach(ConverterView.unitsForCategory(state.convCategory), id: \.self) { u in
                        Text(u.label).tag(u)
                    }
                }
                .frame(width: 78)
                .pickerStyle(.menu)
                .labelsHidden()
            }

            HStack(spacing: 6) {
                Text(convertedString)
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                Picker("", selection: $state.convToUnit) {
                    ForEach(ConverterView.unitsForCategory(state.convCategory), id: \.self) { u in
                        Text(u.label).tag(u)
                    }
                }
                .frame(width: 78)
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
        .onDisappear { state.converterFieldFocused = false }
    }
}

extension String {
    func trimmingTrailingZeros() -> String {
        guard contains(".") else { return self }
        var s = self
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    var firstURL: URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(location: 0, length: utf16.count)
        return detector?.firstMatch(in: self, options: [], range: range)?.url
    }

    var isLikelyURL: Bool {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(" ") || trimmed.contains("\n") { return false }
        if trimmed.count > 2000 { return false }
        return trimmed.firstURL?.scheme?.hasPrefix("http") ?? false
    }
}
