import AppKit

/// Опрашивает системный буфер обмена и сообщает о новом содержимом.
final class ClipboardMonitor {
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?

    var onNewItem: ((ClipItem) -> Void)?
    var isPaused = false

    init() {
        lastChangeCount = pasteboard.changeCount
    }

    func start(interval: TimeInterval = 0.35) {
        stop()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Вызывается после того, как мы сами записали что-то в буфер, чтобы не ловить эхо.
    func acknowledgeOwnWrite() {
        lastChangeCount = pasteboard.changeCount
    }

    private func poll() {
        guard !isPaused else {
            lastChangeCount = pasteboard.changeCount
            return
        }
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        guard var item = ClipReader.read(pasteboard, isShelf: false) else { return }
        ClipReader.stampSource(&item)
        onNewItem?(item)
    }
}
