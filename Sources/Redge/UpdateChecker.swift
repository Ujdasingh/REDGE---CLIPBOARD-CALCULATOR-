import AppKit
import Foundation

enum UpdateChecker {
    static let releasesURL = URL(string: "https://github.com/Ujdasingh/REDGE---CLIPBOARD-CALCULATOR-/releases")!
    private static let latestAPI = URL(string: "https://api.github.com/repos/Ujdasingh/REDGE---CLIPBOARD-CALCULATOR-/releases/latest")!

    static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "2.1"
    }

    static func check(presenting window: NSWindow? = nil) {
        let request = URLRequest(url: latestAPI, timeoutInterval: 8)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let remote = parseTag(from: data)
            DispatchQueue.main.async {
                let alert = NSAlert()
                if let remote, isNewer(remote, than: currentVersion) {
                    alert.messageText = "Redge \(remote) is available"
                    alert.informativeText = "You have \(currentVersion). Open the latest release to download."
                    alert.addButton(withTitle: "Open Release")
                    alert.addButton(withTitle: "Later")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(releasesURL)
                    }
                } else {
                    alert.messageText = "You’re up to date"
                    alert.informativeText = "Redge \(currentVersion) is the latest version this check can see."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }.resume()
    }

    private static func parseTag(from data: Data?) -> String? {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var tag = json["tag_name"] as? String else { return nil }
        if tag.hasPrefix("v") { tag.removeFirst() }
        return tag
    }

    private static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        let n = max(r.count, l.count)
        for i in 0..<n {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }
}
