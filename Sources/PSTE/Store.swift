import AppKit
import Combine
import QuickLookThumbnailing
import SwiftUI

@MainActor
final class Store: ObservableObject {

    enum Filter: String, CaseIterable, Identifiable {
        case all, shelf, text, link, image, files
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "Всё"
            case .shelf: return "Полка"
            case .text: return "Текст"
            case .link: return "Ссылки"
            case .image: return "Картинки"
            case .files: return "Файлы"
            }
        }

        var symbol: String {
            switch self {
            case .all: return "square.stack"
            case .shelf: return "tray.full"
            case .text: return "text.alignleft"
            case .link: return "link"
            case .image: return "photo"
            case .files: return "doc.on.doc"
            }
        }
    }

    @Published private(set) var items: [ClipItem] = []
    @Published var query: String = ""
    @Published var filter: Filter = .all

    /// Монитор нужен, чтобы гасить эхо от собственной записи в буфер.
    weak var monitor: ClipboardMonitor?

    private var saveWork: DispatchWorkItem?
    private let thumbCache = NSCache<NSString, NSImage>()
    /// Для каких элементов превью уже запрашивали у QuickLook.
    private var previewRequests: Set<UUID> = []

    var historyLimit: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: "historyLimit")
            return stored == 0 ? 200 : stored
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "historyLimit")
            trim()
            scheduleSave()
        }
    }

    init() {
        Blobs.prepare()
        load()
    }

    // MARK: - Выборка для интерфейса

    var visible: [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items
            .filter { item in
                switch filter {
                case .all: return true
                case .shelf: return item.isShelf
                case .text: return item.kind == .text || item.kind == .richText || item.kind == .color
                case .link: return item.kind == .link
                case .image: return item.kind == .image
                case .files: return item.kind == .files
                }
            }
            .filter { q.isEmpty || $0.searchHaystack.contains(q) }
            .sorted { lhs, rhs in
                if lhs.pinned != rhs.pinned { return lhs.pinned }
                return lhs.date > rhs.date
            }
    }

    // MARK: - Изменение содержимого

    func add(_ item: ClipItem) {
        if let index = items.firstIndex(where: { $0.fingerprint == item.fingerprint }) {
            // Уже видели это — поднимаем наверх, лишний блоб убираем.
            if items[index].blobName != item.blobName { Blobs.delete(item.blobName) }
            items[index].date = Date()
            if item.isShelf { items[index].isShelf = true }
            if items[index].sourceName == nil { items[index].sourceName = item.sourceName }
        } else {
            items.insert(item, at: 0)
        }
        items.sort { $0.date > $1.date }
        trim()
        scheduleSave()
    }

    @discardableResult
    func addFromPasteboard(_ pb: NSPasteboard, isShelf: Bool) -> Bool {
        guard var item = ClipReader.read(pb, isShelf: isShelf) else { return false }
        if isShelf { item.pinned = false }
        ClipReader.stampSource(&item)
        add(item)
        return true
    }

    /// Добавляет готовые файлы (перетаскивание с «обещанием» из браузера или почты).
    func addFiles(_ urls: [URL], isShelf: Bool) {
        guard var item = ClipReader.filesItem(urls: urls, isShelf: isShelf) else { return }
        item.isShelf = isShelf
        ClipReader.stampSource(&item)
        add(item)
    }

    func remove(_ item: ClipItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        Blobs.delete(items[index].blobName)
        items.remove(at: index)
        scheduleSave()
    }

    func togglePin(_ item: ClipItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].pinned.toggle()
        scheduleSave()
    }

    func clear(keepPinned: Bool = true) {
        let doomed = items.filter { keepPinned ? !($0.pinned || $0.isShelf) : true }
        doomed.forEach { Blobs.delete($0.blobName) }
        let doomedIDs = Set(doomed.map(\.id))
        items.removeAll { doomedIDs.contains($0.id) }
        scheduleSave()
    }

    private func trim() {
        let limit = historyLimit
        guard limit > 0 else { return }
        var seen = 0
        var doomed: [ClipItem] = []
        for item in items where !item.pinned && !item.isShelf {
            seen += 1
            if seen > limit { doomed.append(item) }
        }
        guard !doomed.isEmpty else { return }
        doomed.forEach { Blobs.delete($0.blobName) }
        let doomedIDs = Set(doomed.map(\.id))
        items.removeAll { doomedIDs.contains($0.id) }
    }

    // MARK: - Запись обратно в буфер обмена

    func copyToPasteboard(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()

        switch item.kind {
        case .files:
            let urls = item.urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            if urls.isEmpty {
                pb.setString(item.paths.joined(separator: "\n"), forType: .string)
            } else {
                pb.writeObjects(urls as [NSURL])
            }
        case .image:
            if let url = item.blobURL, let data = try? Data(contentsOf: url) {
                pb.setData(data, forType: .png)
                if let image = NSImage(data: data), let tiff = image.tiffRepresentation {
                    pb.setData(tiff, forType: .tiff)
                }
            }
        case .richText:
            if let url = item.blobURL, let data = try? Data(contentsOf: url) {
                pb.setData(data, forType: .rtf)
            }
            pb.setString(item.text ?? "", forType: .string)
        case .link:
            if let text = item.text, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                (url as NSURL).write(to: pb)
            }
            pb.setString(item.text ?? "", forType: .string)
        case .text, .color:
            pb.setString(item.text ?? "", forType: .string)
        }

        monitor?.acknowledgeOwnWrite()

        // Обновляем «свежесть» без создания дубликата.
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].date = Date()
            items.sort { $0.date > $1.date }
            scheduleSave()
        }
    }

    // MARK: - Превью

    func thumbnail(for item: ClipItem) -> NSImage? {
        let key = item.id.uuidString as NSString
        if let cached = thumbCache.object(forKey: key) { return cached }

        var image: NSImage?
        switch item.kind {
        case .image:
            if let url = item.blobURL, let full = NSImage(contentsOf: url) {
                image = full.thumbnail(maxSide: 72)
            }
        case .files:
            if let path = item.paths.first {
                let icon = NSWorkspace.shared.icon(forFile: path)
                icon.size = NSSize(width: 36, height: 36)
                image = icon
                // Иконка — сразу, а настоящее превью (кадр видео, первая
                // страница документа) приедет чуть позже и заменит её.
                requestPreview(for: item)
            }
        default:
            return nil
        }

        if let image { thumbCache.setObject(image, forKey: key) }
        return image
    }

    private func requestPreview(for item: ClipItem) {
        guard item.paths.count == 1, let path = item.paths.first,
              !previewRequests.contains(item.id),
              FileManager.default.fileExists(atPath: path)
        else { return }
        previewRequests.insert(item.id)

        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: 72, height: 72),
            scale: 2,
            representationTypes: .thumbnail
        )
        let id = item.id
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let representation else { return }
            let cgImage = representation.cgImage
            let image = NSImage(cgImage: cgImage,
                                size: NSSize(width: cgImage.width / 2, height: cgImage.height / 2))
            Task { @MainActor in
                guard let self else { return }
                self.thumbCache.setObject(image.thumbnail(maxSide: 72), forKey: id.uuidString as NSString)
                self.objectWillChange.send()
            }
        }
    }

    // MARK: - Хранение на диске

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.save() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        Blobs.prepare()
        try? data.write(to: Blobs.historyFile, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Blobs.historyFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var loaded = try? decoder.decode([ClipItem].self, from: data) else { return }

        // Файлы могли исчезнуть, пока приложение не работало.
        loaded.removeAll { item in
            if item.kind == .files {
                return !item.paths.contains { FileManager.default.fileExists(atPath: $0) }
            }
            if let blob = item.blobURL {
                return !FileManager.default.fileExists(atPath: blob.path)
            }
            return false
        }
        items = loaded.sorted { $0.date > $1.date }
        collectGarbageBlobs()
    }

    /// Удаляет блобы и принятые файлы, на которые больше никто не ссылается.
    private func collectGarbageBlobs() {
        let fm = FileManager.default

        let referencedBlobs = Set(items.compactMap(\.blobName))
        if let files = try? fm.contentsOfDirectory(atPath: Blobs.directory.path) {
            for file in files where !referencedBlobs.contains(file) {
                try? fm.removeItem(at: Blobs.directory.appendingPathComponent(file))
            }
        }

        let referencedPaths = Set(items.flatMap(\.paths))
        if let dropped = try? fm.contentsOfDirectory(atPath: Blobs.droppedDirectory.path) {
            for file in dropped {
                let url = Blobs.droppedDirectory.appendingPathComponent(file)
                if !referencedPaths.contains(url.path) { try? fm.removeItem(at: url) }
            }
        }
    }
}

extension NSImage {
    func thumbnail(maxSide: CGFloat) -> NSImage {
        let ratio = min(maxSide / max(size.width, 1), maxSide / max(size.height, 1), 1)
        let target = NSSize(width: max(size.width * ratio, 1), height: max(size.height * ratio, 1))
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: target),
             from: NSRect(origin: .zero, size: size),
             operation: .copy,
             fraction: 1)
        thumb.unlockFocus()
        return thumb
    }
}
