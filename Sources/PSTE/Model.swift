import AppKit
import CryptoKit
import Foundation

// MARK: - Типы содержимого буфера

enum ClipKind: String, Codable {
    case text
    case richText
    case link
    case image
    case files
    case color

    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .richText: return "doc.richtext"
        case .link: return "link"
        case .image: return "photo"
        case .files: return "doc.on.doc"
        case .color: return "paintpalette"
        }
    }

    var label: String {
        switch self {
        case .text: return "Текст"
        case .richText: return "Форматированный текст"
        case .link: return "Ссылка"
        case .image: return "Изображение"
        case .files: return "Файлы"
        case .color: return "Цвет"
        }
    }
}

// MARK: - Элемент истории

struct ClipItem: Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var kind: ClipKind
    var date: Date = Date()
    /// Закреплён пользователем — не удаляется при обрезке истории.
    var pinned: Bool = false
    /// Положен на «полку» перетаскиванием, а не через буфер обмена.
    var isShelf: Bool = false
    /// Простой текст (для text/link/color) либо текстовое представление RTF.
    var text: String?
    /// Имя файла в каталоге Blobs (png для картинок, rtf для форматированного текста).
    var blobName: String?
    /// Пути к файлам (для kind == .files).
    var paths: [String] = []
    var sourceName: String?
    var sourceBundleID: String?
    /// Ключ дедупликации.
    var fingerprint: String = ""
    /// Готовая строка с деталями: «1920×1080 · 240 КБ».
    var detail: String?

    var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }

    var blobURL: URL? { blobName.map { Blobs.directory.appendingPathComponent($0) } }

    var title: String {
        switch kind {
        case .files:
            if paths.count == 1 { return urls[0].lastPathComponent }
            return "\(paths.count) \(Plural.files(paths.count))"
        case .image:
            // Снимок, забранный с рабочего стола или из эмулятора, сохраняет
            // своё имя — его и показываем вместо безликого «Изображение».
            if let name = blobName, !name.hasPrefix("png-") { return name }
            return "Изображение"
        case .color:
            return text ?? "Цвет"
        default:
            let raw = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let oneLine = raw.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
            let squeezed = oneLine.split(separator: " ").joined(separator: " ")
            return squeezed.isEmpty ? "(пусто)" : String(squeezed.prefix(200))
        }
    }

    var subtitle: String {
        var parts: [String] = []
        if isShelf {
            parts.append("Полка")
        } else if let app = sourceName, !app.isEmpty {
            parts.append(app)
        }
        if let detail, !detail.isEmpty { parts.append(detail) }
        switch kind {
        case .text, .richText:
            let count = (text ?? "").count
            parts.append("\(count) \(Plural.chars(count))")
        case .files where paths.count == 1:
            // Файлы в своём хранилище показывать по пути бессмысленно.
            let folder = urls[0].deletingLastPathComponent().path
            if !folder.hasPrefix(Blobs.root.path) {
                parts.append(folder.abbreviatingHome)
            }
        default:
            break
        }
        return parts.joined(separator: " · ")
    }

    /// Текст для поиска.
    var searchHaystack: String {
        ([title, subtitle, text ?? ""] + paths).joined(separator: " ").lowercased()
    }
}

// MARK: - Кодирование с устойчивостью к смене схемы

extension ClipItem: Codable {
    enum CodingKeys: String, CodingKey {
        case id, kind, date, pinned, isShelf, text, blobName, paths
        case sourceName, sourceBundleID, fingerprint, detail
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        kind = (try? c.decode(ClipKind.self, forKey: .kind)) ?? .text
        date = (try? c.decode(Date.self, forKey: .date)) ?? Date()
        pinned = (try? c.decode(Bool.self, forKey: .pinned)) ?? false
        isShelf = (try? c.decode(Bool.self, forKey: .isShelf)) ?? false
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        blobName = try? c.decodeIfPresent(String.self, forKey: .blobName)
        paths = (try? c.decode([String].self, forKey: .paths)) ?? []
        sourceName = try? c.decodeIfPresent(String.self, forKey: .sourceName)
        sourceBundleID = try? c.decodeIfPresent(String.self, forKey: .sourceBundleID)
        fingerprint = (try? c.decode(String.self, forKey: .fingerprint)) ?? ""
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
    }
}

// MARK: - Хранилище блобов

enum Blobs {
    /// Имя, под которым приложение жило до переименования, — историю
    /// пользователя переносим, а не теряем.
    private static let legacyFolderName = "ClipShelf"

    static let root: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = base.appendingPathComponent("PSTE", isDirectory: true)
        let legacy = base.appendingPathComponent(legacyFolderName, isDirectory: true)
        if !fm.fileExists(atPath: current.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: current)
        }
        return current
    }()

    /// Прежнее расположение — нужно, чтобы не принять его за «чужой» путь
    /// в настройках эмулятора.
    static var legacyRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(legacyFolderName, isDirectory: true)
    }

    static let directory: URL = root.appendingPathComponent("Blobs", isDirectory: true)
    /// Сюда переезжают файлы, которые приложение-источник отдаёт «обещанием»
    /// (картинка из браузера, вложение из почты).
    static let droppedDirectory: URL = root.appendingPathComponent("Dropped", isDirectory: true)
    static let historyFile: URL = root.appendingPathComponent("history.json")

    static func prepare() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @discardableResult
    static func write(_ data: Data, ext: String, name: String? = nil) -> String? {
        prepare()
        let fileName = name ?? "\(ext)-\(Self.stamp())-\(UUID().uuidString.prefix(6)).\(ext)"
        let url = directory.appendingPathComponent(fileName)
        do {
            try data.write(to: url)
            return fileName
        } catch {
            return nil
        }
    }

    /// Свободное имя в хранилище: снимок экрана переезжает сюда со своим
    /// человеческим именем, чтобы его было приятно вытаскивать обратно.
    static func uniqueURL(for fileName: String, in folder: URL? = nil) -> URL {
        let folder = folder ?? directory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = folder.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }

    static func delete(_ name: String?) {
        guard let name else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }
}

// MARK: - Мелкие утилиты

enum Plural {
    static func pick(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return one }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return few }
        return many
    }
    static func files(_ n: Int) -> String { pick(n, "файл", "файла", "файлов") }
    static func chars(_ n: Int) -> String { pick(n, "символ", "символа", "символов") }
    static func items(_ n: Int) -> String { pick(n, "элемент", "элемента", "элементов") }
}

extension String {
    var abbreviatingHome: String {
        let home = NSHomeDirectory()
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }

    var sha256: String {
        let digest = SHA256.hash(data: Data(utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension Data {
    var sha256: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}

enum Fmt {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.unitsStyle = .short
        return f
    }()

    static func ago(_ date: Date) -> String {
        let delta = Date().timeIntervalSince(date)
        if delta < 60 { return "только что" }
        return relative.localizedString(for: date, relativeTo: Date())
    }
}
