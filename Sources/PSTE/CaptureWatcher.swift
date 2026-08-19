import AppKit

/// Откуда прилетел файл — от системы или из Android-эмулятора.
enum CaptureOrigin {
    case system
    case emulator
}

/// Следит за папками, куда падают снимки экрана и записи видео, и сообщает
/// о каждом новом файле. Что с ним делать — решает `AppDelegate`.
///
/// Правил два:
/// * системные папки (папка снимков macOS и рабочий стол) — берём только то,
///   что похоже на снимок экрана или запись, чтобы не трогать чужие файлы;
/// * своя папка эмулятора — берём всё, потому что туда пишет только эмулятор.
@MainActor
final class CaptureWatcher {

    struct Rule {
        let url: URL
        let origin: CaptureOrigin
        /// Для своей папки — забираем любой появившийся файл.
        let acceptsAnyFile: Bool
    }

    var onCapture: ((URL, CaptureOrigin) -> Void)?

    private var sources: [DispatchSourceFileSystemObject] = []
    private var rules: [Rule] = []
    private var seen: [String: Set<String>] = [:]
    private var since = Date()

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "captureScreenshots") as? Bool ?? true
    }

    // MARK: - Запуск

    func start() {
        stop()
        guard isEnabled else { return }

        since = Date()
        rules = Self.currentRules()
        seen = [:]

        for rule in rules {
            seen[rule.url.path] = Set(names(in: rule.url))
            watch(rule)
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources = []
    }

    /// Перезапуск только при реальных изменениях: настройку дёргает каждый
    /// переключатель в меню, а пересоздавать наблюдателей каждый раз незачем.
    func restart() {
        let fresh = Self.currentRules().map(\.url.path)
        let isRunning = !sources.isEmpty
        guard isEnabled != isRunning || fresh != rules.map(\.url.path) else { return }
        isEnabled ? start() : stop()
    }

    /// Файл забрали к себе — помнить о нём больше не нужно.
    func forget(_ url: URL) {
        let folder = url.deletingLastPathComponent().path
        seen[folder]?.remove(url.lastPathComponent)
    }

    private func watch(_ rule: Rule) {
        let descriptor = open(rule.url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename],
            queue: .main
        )
        source.setEventHandler {
            // Небольшая пауза: файл дописывается уже после события.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                MainActor.assumeIsolated { [weak self] in self?.scan(rule) }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        sources.append(source)
    }

    // MARK: - Поиск новых файлов

    private func names(in folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    private func scan(_ rule: Rule) {
        guard isEnabled else { return }
        let fm = FileManager.default
        var known = seen[rule.url.path] ?? []

        for name in names(in: rule.url) where !known.contains(name) {
            known.insert(name)
            let url = rule.url.appendingPathComponent(name)
            guard accepts(url, rule: rule) else { continue }
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                  let created = (attributes[.creationDate] as? Date) ?? (attributes[.modificationDate] as? Date),
                  created >= since.addingTimeInterval(-2)
            else { continue }
            deliver(url, rule: rule)
        }
        seen[rule.url.path] = known
    }

    /// Видео пишется долго — отдаём файл только когда он перестал расти.
    private func deliver(_ url: URL, rule: Rule) {
        guard Self.videoExtensions.contains(url.pathExtension.lowercased()) else {
            onCapture?(url, rule.origin)
            return
        }
        waitUntilStable(url, attemptsLeft: 120, lastSize: -1) { [weak self] in
            self?.onCapture?(url, rule.origin)
        }
    }

    private func waitUntilStable(_ url: URL, attemptsLeft: Int, lastSize: Int,
                                 completion: @escaping () -> Void) {
        guard attemptsLeft > 0 else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        guard let size else { return }   // файл исчез
        if size > 0, size == lastSize {
            completion()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                self.waitUntilStable(url, attemptsLeft: attemptsLeft - 1, lastSize: size, completion: completion)
            }
        }
    }

    // MARK: - Что считаем своим

    static let imageExtensions = ["png", "jpg", "jpeg", "heic", "tiff", "bmp"]
    static let videoExtensions = ["webm", "mp4", "mov", "m4v", "gif"]

    private func accepts(_ url: URL, rule: Rule) -> Bool {
        let name = url.lastPathComponent
        guard !name.hasPrefix("."), !name.hasPrefix("~") else { return false }
        let ext = url.pathExtension.lowercased()
        guard !["tmp", "part", "download", "crdownload", "partial"].contains(ext) else { return false }

        if rule.acceptsAnyFile {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return !isDirectory.boolValue
        }

        let base = url.deletingPathExtension().lastPathComponent
        if Self.imageExtensions.contains(ext) {
            return Self.screenshotPatterns().contains { base.localizedCaseInsensitiveContains($0) }
        }
        if Self.videoExtensions.contains(ext) {
            return Self.recordingPatterns.contains { base.localizedCaseInsensitiveContains($0) }
        }
        return false
    }

    /// Имена снимков локализованы, плюс пользователь может задать своё в настройках.
    private static func screenshotPatterns() -> [String] {
        var patterns = ["Screenshot", "Screen Shot", "Снимок экрана", "CleanShot", "Shottr"]
        if let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "name"),
           !custom.isEmpty {
            patterns.append(custom)
        }
        return patterns
    }

    /// Записи экрана: macOS, Android Studio и эмулятор называют их по-разному.
    private static let recordingPatterns = [
        "Screen Recording", "Screen_recording", "screen-recording", "screenrecord",
        "Запись экрана", "Screenshot", "emulator-recording"
    ]

    // MARK: - Папки

    static func currentRules() -> [Rule] {
        var rules: [Rule] = []
        var paths = Set<String>()
        let fm = FileManager.default

        func add(_ url: URL, origin: CaptureOrigin, anyFile: Bool) {
            guard !paths.contains(url.path) else { return }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
            paths.insert(url.path)
            rules.append(Rule(url: url, origin: origin, acceptsAnyFile: anyFile))
        }

        if EmulatorCapture.isEnabled {
            try? fm.createDirectory(at: EmulatorCapture.folder, withIntermediateDirectories: true)
            add(EmulatorCapture.folder, origin: .emulator, anyFile: true)
        }
        add(screenshotDirectory(), origin: .system, anyFile: false)
        add(fm.urls(for: .desktopDirectory, in: .userDomainMask)[0], origin: .system, anyFile: false)

        // Эмулятор мог остаться настроенным на другую папку (например, если
        // PSTE выключали) — присматриваем и за ней.
        if let configured = EmulatorCapture.currentSavePath, !configured.isEmpty {
            add(URL(fileURLWithPath: configured), origin: .system, anyFile: false)
        }
        return rules
    }

    /// Куда macOS сохраняет снимки (⌘⇧5 → «Сохранить в»).
    static func screenshotDirectory() -> URL {
        let defaults = UserDefaults(suiteName: "com.apple.screencapture")
        if let raw = defaults?.string(forKey: "location") {
            let expanded = (raw as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: expanded)
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }
}
