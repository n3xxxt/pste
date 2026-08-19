import Foundation

/// Перенаправляет папку сохранения Android-эмулятора на свою.
///
/// Эмулятор держит её в собственных настройках (`com.android.Emulator`,
/// ключ `set.savePath`) — туда попадают и снимки экрана, и записи видео.
/// Пока PSTE запущен, эмулятор пишет в его папку, и на рабочем столе
/// ничего не остаётся; при выходе прежний путь возвращается на место,
/// чтобы без PSTE снимки не терялись.
enum EmulatorCapture {
    private static let domain = "com.android.Emulator"
    private static let pathKey = "set.savePath"
    private static let backupKey = "emulatorSavePathBackup"

    static var folder: URL {
        Blobs.root.appendingPathComponent("Emulator", isDirectory: true)
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "captureEmulator") as? Bool ?? true
    }

    static var currentSavePath: String? {
        UserDefaults(suiteName: domain)?.string(forKey: pathKey)
    }

    static func syncWithSetting() {
        isEnabled ? apply() : restore()
    }

    static func apply() {
        guard let defaults = UserDefaults(suiteName: domain) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let current = defaults.string(forKey: pathKey)
        guard current != folder.path else { return }
        // Запоминаем только настоящий пользовательский путь: если там уже
        // наша папка (в том числе от прежней версии), запоминать нечего.
        if let current, !current.isEmpty, !isOwnFolder(current) {
            UserDefaults.standard.set(current, forKey: backupKey)
        }
        defaults.set(folder.path, forKey: pathKey)
        defaults.synchronize()
    }

    /// Путь принадлежит приложению (в том числе каталогу прежней версии)?
    private static func isOwnFolder(_ path: String) -> Bool {
        path.hasPrefix(Blobs.root.path) || path.hasPrefix(Blobs.legacyRoot.path)
    }

    static func restore() {
        guard let defaults = UserDefaults(suiteName: domain) else { return }
        guard let current = defaults.string(forKey: pathKey), isOwnFolder(current) else { return }

        let fallback = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask)[0].path
        let previous = UserDefaults.standard.string(forKey: backupKey) ?? fallback
        defaults.set(previous, forKey: pathKey)
        defaults.synchronize()
    }
}
