// Sets a custom icon attribute directly on a file or folder using NSWorkspace.setIcon.
// This writes to the bundle's `Icon\r` resource and `com.apple.FinderInfo` xattr —
// Finder reads these directly, bypassing iconservicesd entirely.
//
// Usage: swift set_bundle_icon.swift <icon.icns> <target>

import Cocoa

guard CommandLine.arguments.count >= 3 else {
    print("Usage: swift set_bundle_icon.swift <icon.icns> <target>")
    exit(2)
}

let iconPath = CommandLine.arguments[1]
let targetPath = CommandLine.arguments[2]

guard let img = NSImage(contentsOfFile: iconPath) else {
    print("Could not load icon at \(iconPath)")
    exit(1)
}

let ok = NSWorkspace.shared.setIcon(img, forFile: targetPath, options: [])
if ok {
    print("Custom icon set on \(targetPath)")
} else {
    print("setIcon returned false for \(targetPath)")
    exit(1)
}
