import AppKit
import SwiftUI

enum TextTools {
    static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func upper(_ text: String) -> String { text.uppercased() }
    static func lower(_ text: String) -> String { text.lowercased() }

    static func extractNumbers(_ text: String) -> String {
        let parts = text.split { !$0.isNumber && $0 != "." && $0 != "-" && $0 != "," }
            .map(String.init)
            .filter { !$0.isEmpty && $0.contains(where: \.isNumber) }
        return parts.joined(separator: "\n")
    }

    static func splitTabs(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\t", with: "\n")
            .replacingOccurrences(of: "  +", with: "\n", options: .regularExpression)
    }

    static func hexColor(from text: String) -> Color? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var hex = trimmed
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 3 || hex.count == 6,
              hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard let value = UInt32(hex, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        return Color(red: r, green: g, blue: b)
    }
}
