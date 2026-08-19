import AppKit

/// Иконка в системной строке меню. Умеет принимать файлы прямо на себя —
/// как в Dropover: бросил на иконку, и вещь легла на полку.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let store: Store
    private let dropZone = MenuBarDropView()

    var onToggle: (() -> Void)?
    var onDropOpened: (() -> Void)?

    init(store: Store) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "PSTE")
                ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "PSTE")
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly

            dropZone.frame = button.bounds
            dropZone.autoresizingMask = [.width, .height]
            dropZone.onClick = { [weak self] in self?.onToggle?() }
            dropZone.onTargeted = { [weak self] targeted in
                // Полка «распахивается» под курсором, пока файл ещё в воздухе.
                if targeted { self?.onDropOpened?() }
            }
            dropZone.onDrop = { [weak self] pasteboard in
                guard let self else { return false }
                let added = self.store.addFromPasteboard(pasteboard, isShelf: true)
                if added { self.onDropOpened?() }
                return added
            }
            dropZone.onPromisedFiles = { [weak self] urls in
                guard let self else { return }
                self.store.addFiles(urls, isShelf: true)
                self.onDropOpened?()
            }
            button.addSubview(dropZone)
        }
    }

    var frameInScreen: NSRect {
        guard let button = statusItem.button, let window = button.window else { return .zero }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func setHighlighted(_ highlighted: Bool) {
        statusItem.button?.highlight(highlighted)
    }

    func setBadge(_ count: Int) {
        statusItem.button?.toolTip = count > 0
            ? "PSTE — \(count) \(Plural.items(count))"
            : "PSTE"
    }
}

/// Невидимый слой поверх иконки: клик открывает полку, а перетаскивание
/// обрабатывается тем же приёмником, что и в самом окне.
final class MenuBarDropView: DropCatcherView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
