import AppKit
import CoreGraphics

/// Detects Apple's *active* screenshot overlay (⌘⇧4 crosshair / ⌘⇧5 toolbar).
/// `screencaptureui` keeps running after you finish a capture, so we must
/// ignore leftover processes and the small post-shot thumbnail.
enum ScreenshotGuard {
    private static let ownerNeedles = [
        "screencaptureui",
        "screencapture",
        "screenshot",
    ]

    private static var cached = false
    private static var cachedAt: TimeInterval = 0
    private static let cacheTTL: TimeInterval = 0.12

    static var isActive: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if now - cachedAt < cacheTTL { return cached }
        cached = detect()
        cachedAt = now
        return cached
    }

    private static func detect() -> Bool {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }

        let largestScreenArea = NSScreen.screens
            .map { $0.frame.width * $0.frame.height }
            .max() ?? 0

        for window in info {
            let owner = ((window[kCGWindowOwnerName as String] as? String) ?? "").lowercased()
            guard ownerNeedles.contains(where: { owner.contains($0) }) else { continue }
            if let alpha = window[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue < 0.05 {
                continue
            }
            guard let rect = bounds(of: window), isCaptureChrome(rect, largestScreenArea: largestScreenArea) else {
                continue
            }
            return true
        }
        return false
    }

    /// Selection dimmer covers most of the display. The ⌘⇧5 bar is wide and short.
    /// The floating thumbnail after a shot is small — that must not count.
    private static func isCaptureChrome(_ rect: CGRect, largestScreenArea: CGFloat) -> Bool {
        let w = rect.width
        let h = rect.height
        let area = w * h
        if w < 40 || h < 20 || area < 8_000 { return false }
        if largestScreenArea > 0, area >= largestScreenArea * 0.35 { return true }
        // Toolbar / options strip
        return w >= 280 && h >= 32 && h <= 200
    }

    private static func bounds(of window: [String: Any]) -> CGRect? {
        guard let b = window[kCGWindowBounds as String] as? [String: Any] else { return nil }
        func num(_ key: String) -> CGFloat? {
            (b[key] as? NSNumber).map { CGFloat(truncating: $0) }
        }
        guard let x = num("X"), let y = num("Y"), let w = num("Width"), let h = num("Height") else {
            return nil
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
