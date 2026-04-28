import Foundation
import AppKit

struct PersistedItem: Codable {
    let id: UUID
    let date: Date
    let kind: String
    let text: String?
    let imageFilename: String?
    let ocrText: String?
    let isPinned: Bool
}

final class PersistenceStore {
    private let dirURL: URL
    private let jsonURL: URL
    private let imagesURL: URL

    init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        dirURL = appSupport.appendingPathComponent("Redge", isDirectory: true)
        imagesURL = dirURL.appendingPathComponent("images", isDirectory: true)
        jsonURL = dirURL.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
    }

    func save(_ items: [ClipboardItem]) {
        var persisted: [PersistedItem] = []
        var seenImageIds = Set<UUID>()
        for item in items {
            switch item.content {
            case .text(let s):
                persisted.append(PersistedItem(
                    id: item.id, date: item.date, kind: "text",
                    text: s, imageFilename: nil,
                    ocrText: item.ocrText, isPinned: item.isPinned
                ))
            case .image(let data):
                let filename = "\(item.id.uuidString).png"
                let url = imagesURL.appendingPathComponent(filename)
                if !FileManager.default.fileExists(atPath: url.path) {
                    try? data.write(to: url)
                }
                seenImageIds.insert(item.id)
                persisted.append(PersistedItem(
                    id: item.id, date: item.date, kind: "image",
                    text: nil, imageFilename: filename,
                    ocrText: item.ocrText, isPinned: item.isPinned
                ))
            }
        }
        if let allFiles = try? FileManager.default.contentsOfDirectory(at: imagesURL, includingPropertiesForKeys: nil) {
            for url in allFiles {
                let name = url.deletingPathExtension().lastPathComponent
                if let id = UUID(uuidString: name), !seenImageIds.contains(id) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(persisted)
            try data.write(to: jsonURL)
        } catch {
            print("Redge save failed: \(error)")
        }
    }

    func load() -> [ClipboardItem] {
        guard let data = try? Data(contentsOf: jsonURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let persisted = try? decoder.decode([PersistedItem].self, from: data) else {
            return []
        }
        return persisted.compactMap { p in
            switch p.kind {
            case "text":
                guard let text = p.text else { return nil }
                return ClipboardItem(id: p.id, content: .text(text), date: p.date,
                                     ocrText: p.ocrText, isPinned: p.isPinned)
            case "image":
                guard let filename = p.imageFilename,
                      let imgData = try? Data(contentsOf: imagesURL.appendingPathComponent(filename)) else {
                    return nil
                }
                return ClipboardItem(id: p.id, content: .image(imgData), date: p.date,
                                     ocrText: p.ocrText, isPinned: p.isPinned)
            default:
                return nil
            }
        }
    }
}
