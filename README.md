# Redge — Clipboard, Calculator & Repeat

> A gesture-triggered clipboard manager for macOS. Slide your cursor into the screen edge — the panel slides in. Move away — it hides. No Dock icon, no window to babysit.

**v2.1** adds Settings, a first-run permission choice, Auto-paste on by default (fills the selected Excel/Numbers cell), text transforms, named notes, recent fills, and file clips. **Repeat stays off** until you turn it on.

![Redge panel](docs/hero.png)
<!-- Replace docs/hero.png with a real screenshot once you've taken one. -->

---

## Features

| | |
|---|---|
| **Edge trigger** | Cursor → screen edge (right or left, configurable) → panel slides in. Move off → hides. Stays out of macOS screenshot mode. |
| **Settings** | Hotkeys, edge side/thickness/height, hide delay, history size, Auto-paste, Repeat, notes export/import, check for updates. |
| **Global hotkey** | `⌃⌘V` toggles the panel (customizable). Auto-focuses search. |
| **Auto-paste** | Click a clip to fill the selected Excel/Numbers cell, or paste into the previous app. On by default. Needs Accessibility. |
| **Repeat Last** | Off until enabled. Then `⌘⌥R` (customizable) replays the last shortcut, shortcut+move, or Finder drop. Needs Accessibility + Input Monitoring. |
| **Text + images + files** | Captures all three. Hex colors show a swatch. URL rows open in the browser. |
| **Transforms** | Right-click a text clip: trim, UPPER/lower, extract numbers, split tabs. |
| **Recent fills** | Last pasted/filled values sit above Temp for one-click reuse. |
| **OCR search** | Images are OCR’d by Vision. Search matches text *inside* screenshots. |
| **Pin items** | Hover a row → pin. Pinned items survive Clear and never expire. |
| **Notes** | Bookmark a Temp row, or add a titled snippet. Export/import JSON from Settings. Notes never expire. |
| **Calculator** | 4-function calc with **%**, history, and a unit converter. |
| **Password-aware** | Skips items copied by 1Password / Bitwarden / Keychain. |
| **Launch at Login** | Toggle from Settings or the menu-bar icon. |
| **Menu-bar only** | No Dock icon, no app switcher clutter. |

---

## Install

Requires macOS 13+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/Ujdasingh/REDGE---CLIPBOARD-CALCULATOR-.git
cd REDGE---CLIPBOARD-CALCULATOR-
./build-app.sh
cp -R Redge.app /Applications/
open /Applications/Redge.app
```

The build script generates the icon, compiles a release binary, writes Info.plist (`&amp;` escaped), and signs with a stable **Redge Developer** identity so Accessibility does not reset on every rebuild. Always run **`/Applications/Redge.app`** — not a `swift run` or Downloads copy.

### Share as a DMG

```bash
./create-dmg.sh
```

Output: `Redge-2.1.0.dmg`. Recipients open the DMG and drag the app to Applications.

Self-signed builds may need **System Settings → Privacy & Security → Open Anyway**, or right-click → **Open**.

### Notarized distribution (Apple Developer ID)

Notarization needs a paid Apple Developer account and a **Developer ID Application** certificate. This repo cannot create those for you.

```bash
# After installing the certificate and storing notary credentials:
#   xcrun notarytool store-credentials redge
NOTARY_PROFILE=redge ./scripts/notarize.sh
SKIP_BUILD=1 ./create-dmg.sh
```

Until then, **Check for Updates…** in Settings compares `CFBundleShortVersionString` to [GitHub Releases](https://github.com/Ujdasingh/REDGE---CLIPBOARD-CALCULATOR-/releases/latest).

---

## Usage

| Action | How |
|---|---|
| Open panel | Cursor → configured edge, vertical center. Or the panel hotkey. |
| Settings | Menu bar → Settings…, or the gear on the panel. |
| Hide panel | Move cursor off. Or the panel hotkey again. |
| Fill / paste | Click a row (Auto-paste on). Excel/Numbers get the selected cell. |
| Repeat last | Enable Repeat in Settings, then press the Repeat hotkey. |
| Transforms | Right-click a text row. |
| Pin panel open | Pin icon top-right of the panel. |
| Notes | Notes sub-tab → + for a titled snippet. Settings → Export/Import. |
| Calculator | Calculator tab at the top. |

---

## Permissions

Redge does not phone home. Data lives in `~/Library/Application Support/Redge/`.

On first launch, choose **Clipboard only** or **Clipboard + Repeat**:

- **Clipboard only** — history, OCR, calculator, Auto-paste. Accessibility is requested when you fill a cell.
- **Clipboard + Repeat** — also records shortcuts and last actions. Adds Input Monitoring.

Always enable the **Redge** icon in Privacy settings, not Terminal.

---

## Architecture

Swift Package.

```
Sources/Redge/
├── main.swift              — entry; .accessory activation policy
├── AppDelegate.swift       — status item, edge polling, hotkeys, onboarding
├── AppSettings.swift       — persisted preferences + hotkey labels
├── SettingsWindow.swift    — Settings panel
├── OnboardingWindow.swift  — first-run Clipboard vs Repeat
├── RepeatEngine.swift      — last action capture + replay (off by default)
├── ClipboardManager.swift  — pasteboard, OCR, notes, recent fills
├── ClipboardWindow.swift   — NSPanel + SwiftUI
├── TextTools.swift         — trim / case / numbers / color
├── Calculator.swift        — calc + converter
├── Persistence.swift       — JSON + image-blob store
├── HotKey.swift            — Carbon RegisterEventHotKey
├── AutoPaste.swift         — Excel/Numbers fill + ⌘V
├── UpdateChecker.swift     — GitHub releases/latest
└── ScreenshotGuard.swift   — hide/freeze during screenshots
```

---

## License

[MIT](LICENSE)
