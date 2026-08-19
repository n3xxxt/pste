import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private let monitor = ClipboardMonitor()
    private let captures = CaptureWatcher()
    private var panel: PanelController!
    private var statusItem: StatusItemController!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.monitor = monitor

        panel = PanelController(store: store)
        statusItem = StatusItemController(store: store)

        panel.anchorFrame = { [weak self] in self?.statusItem.frameInScreen ?? .zero }
        panel.onVisibilityChange = { [weak self] visible in
            self?.statusItem.setHighlighted(visible)
        }

        statusItem.onToggle = { [weak self] in self?.panel.toggle() }
        statusItem.onDropOpened = { [weak self] in
            guard let self, !self.panel.isVisible else { return }
            self.panel.show()
        }

        monitor.onNewItem = { [weak self] item in
            guard let self else { return }
            self.store.add(item)
            self.statusItem.setBadge(self.store.items.count)
        }
        monitor.start()
        EmulatorCapture.syncWithSetting()
        captures.onCapture = { [weak self] url, origin in self?.handleCapture(url, from: origin) }
        captures.start()

        // Пользователь мог переключить настройку в меню — перечитываем её.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                EmulatorCapture.syncWithSetting()
                self?.captures.restart()
            }
        }

        registerHotKey()
        NotificationCenter.default.addObserver(
            forName: .hotKeyPreferenceChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotKey() }
        }

        statusItem.setBadge(store.items.count)
    }

    // MARK: - Сочетание вызова

    /// Перерегистрирует горячую клавишу. Если сочетание уже занято другой
    /// программой, система откажет — об этом узнает интерфейс.
    private func registerHotKey() {
        hotKey = nil
        let preference = HotKeyPreference.current
        hotKey = HotKey(keyCode: preference.keyCode, modifiers: preference.modifiers) { [weak self] in
            self?.panel.toggle()
        }
        HotKeyPreference.isRegistered = hotKey != nil
        if hotKey == nil {
            NSLog("PSTE: не удалось занять сочетание \(preference.display) — вероятно, оно занято")
        }
    }

    // MARK: - Снимки экрана и записи

    /// Картинки разбираем как изображение, всё остальное (видео эмулятора,
    /// записи экрана) — как файл, который можно вставить и перетащить.
    private func handleCapture(_ url: URL, from origin: CaptureOrigin) {
        let ext = url.pathExtension.lowercased()
        if CaptureWatcher.imageExtensions.contains(ext) {
            handleScreenshot(url, from: origin)
        } else {
            handleRecording(url, from: origin)
        }
    }

    /// Файл эмулятора всегда забираем к себе: он лежит в нашей же папке,
    /// и оставлять его там смысла нет.
    private func shouldTakeFile(from origin: CaptureOrigin) -> Bool {
        if origin == .emulator { return true }
        return UserDefaults.standard.object(forKey: "moveScreenshots") as? Bool ?? true
    }

    private func sourceLabel(for origin: CaptureOrigin, isVideo: Bool) -> String {
        switch origin {
        case .emulator: return isVideo ? "Эмулятор · запись" : "Эмулятор"
        case .system: return isVideo ? "Запись экрана" : "Снимок экрана"
        }
    }

    /// Видео в буфер обмена кладём файлом: так его можно вставить в чат,
    /// в Finder или в редактор, и вытащить перетаскиванием из полки.
    private func handleRecording(_ url: URL, from origin: CaptureOrigin) {
        let fm = FileManager.default
        var final = url

        if shouldTakeFile(from: origin) {
            let target = Blobs.uniqueURL(for: url.lastPathComponent, in: Blobs.droppedDirectory)
            if (try? fm.moveItem(at: url, to: target)) != nil {
                final = target
                captures.forget(url)
            }
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([final as NSURL])
        monitor.acknowledgeOwnWrite()

        guard var item = ClipReader.filesItem(urls: [final], isShelf: false) else { return }
        item.sourceName = sourceLabel(for: origin, isVideo: true)
        store.add(item)
        statusItem.setBadge(store.items.count)
    }

    /// Снимок кладём в буфер обмена и в историю. Если включено «забирать к себе»,
    /// файл переезжает в хранилище полки — на рабочем столе не остаётся ничего.
    private func handleScreenshot(_ url: URL, from origin: CaptureOrigin) {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: url) else { return }

        let isPNG = url.pathExtension.lowercased() == "png"
        let png = isPNG ? data : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
        guard let png, let rep = NSBitmapImageRep(data: png) else { return }

        // В буфер обмена — и сразу гасим эхо, чтобы не завести второй такой же элемент.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
        monitor.acknowledgeOwnWrite()

        // В историю.
        Blobs.prepare()
        let takeFile = shouldTakeFile(from: origin)
        var blobName: String?

        if takeFile, isPNG {
            let target = Blobs.uniqueURL(for: url.lastPathComponent)
            if (try? fm.moveItem(at: url, to: target)) != nil {
                blobName = target.lastPathComponent
                captures.forget(url)
            }
        }
        if blobName == nil {
            blobName = Blobs.write(png, ext: "png")
            // Формат не PNG (или перенос не удался): копию сохранили, оригинал убираем.
            if takeFile {
                try? fm.removeItem(at: url)
                captures.forget(url)
            }
        }
        guard let blobName else { return }

        var item = ClipItem(kind: .image)
        item.blobName = blobName
        item.detail = "\(rep.pixelsWide)×\(rep.pixelsHigh) · "
            + Fmt.bytes.string(fromByteCount: Int64(png.count))
        item.fingerprint = "image:" + png.sha256
        item.sourceName = sourceLabel(for: origin, isVideo: false)
        store.add(item)
        statusItem.setBadge(store.items.count)
    }

    /// Повторный запуск из Finder / Dock просто показывает полку.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        panel.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        captures.stop()
        // Без PSTE эмулятор должен снова писать туда, куда писал раньше,
        // иначе снимки будут молча уходить в невидимую папку.
        EmulatorCapture.restore()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
