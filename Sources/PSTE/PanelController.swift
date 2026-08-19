import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
final class PanelController {
    static let width: CGFloat = 440
    static let height: CGFloat = 560

    private let panel: FloatingPanel
    private let store: Store
    private let dropState = DropState()
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private weak var previousApp: NSRunningApplication?

    /// Откуда «выезжает» окно — рамка иконки в меню-баре.
    var anchorFrame: () -> NSRect = { .zero }
    var onVisibilityChange: ((Bool) -> Void)?

    var isVisible: Bool { panel.isVisible }

    init(store: Store) {
        self.store = store

        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow

        let root = ContentView()
            .environmentObject(store)
            .environmentObject(dropState)
            .environment(\.panelController, self)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.height)
        hosting.autoresizingMask = [.width, .height]

        // Приёмник перетаскивания — предок SwiftUI-иерархии.
        let catcher = DropCatcherView(frame: hosting.frame)
        catcher.addSubview(hosting)
        catcher.onTargeted = { [weak self] targeted in
            self?.dropState.isTargeted = targeted
        }
        catcher.onDrop = { [weak store] pasteboard in
            store?.addFromPasteboard(pasteboard, isShelf: true) ?? false
        }
        catcher.onPromisedFiles = { [weak store] urls in
            store?.addFiles(urls, isShelf: true)
        }
        panel.contentView = catcher

        panel.onCancel = { [weak self] in
            guard let self else { return }
            if store.query.isEmpty {
                self.hide(reason: "Esc")
            } else {
                store.query = ""
            }
        }
    }

    // MARK: - Показ и скрытие

    func toggle() {
        isVisible ? hide(reason: "переключатель") : show()
    }

    func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        position()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        startMouseMonitors()
        onVisibilityChange?(true)
        NotificationCenter.default.post(name: .panelDidShow, object: nil)
    }

    func hide(reason: String = "—") {
        guard panel.isVisible else { return }
        if ProcessInfo.processInfo.environment["PSTE_DEBUG"] != nil {
            NSLog("PSTE: закрытие панели, причина: \(reason)")
        }
        stopMouseMonitors()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.10
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
        store.query = ""
        onVisibilityChange?(false)
    }

    // MARK: - Применение элемента

    /// Кладёт элемент в буфер обмена и, если разрешено, сразу вставляет его
    /// в то приложение, из которого панель была вызвана.
    func activate(_ item: ClipItem) {
        store.copyToPasteboard(item)

        let defaults = UserDefaults.standard
        let pasteDirectly = defaults.object(forKey: "pasteDirectly") as? Bool ?? true
        let closeAfterCopy = defaults.object(forKey: "closeAfterCopy") as? Bool ?? true

        if pasteDirectly && Paster.isTrusted {
            returnFocus(thenPaste: true, reason: "выбран элемент, вставка")
        } else if closeAfterCopy {
            returnFocus(thenPaste: false, reason: "выбран элемент")
        }
    }

    /// Отдаёт фокус приложению, которое было активным до открытия панели,
    /// и — при необходимости — жмёт ⌘V за пользователя.
    func returnFocus(thenPaste: Bool, reason: String = "возврат фокуса") {
        let app = previousApp
        hide(reason: reason)
        guard thenPaste else {
            app?.activate()
            return
        }
        app?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Paster.paste()
        }
    }

    private func position() {
        let anchor = anchorFrame()

        // Экран выбираем по курсору: в полноэкранном пространстве строка меню
        // скрыта, и рамка иконки уезжает за верх экрана — по ней экран не найти.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

        let anchorOnScreen = anchor != .zero
            && anchor.midX >= visible.minX && anchor.midX <= visible.maxX

        var x = anchorOnScreen ? anchor.midX - Self.width / 2 : visible.maxX - Self.width - 12
        x = min(max(x, visible.minX + 8), visible.maxX - Self.width - 8)

        // Верхний край — под иконкой, но не выше видимой области экрана.
        let top = min(anchorOnScreen ? anchor.minY : visible.maxY, visible.maxY)
        var y = top - Self.height - 6
        y = min(y, visible.maxY - Self.height - 8)
        y = max(y, visible.minY + 8)

        panel.setFrame(NSRect(x: x, y: y, width: Self.width, height: Self.height), display: false)

        if ProcessInfo.processInfo.environment["PSTE_DEBUG"] != nil {
            NSLog("PSTE: anchor=\(anchor) screen=\(screen.frame) visible=\(visible) → panel=\(panel.frame)")
            logDragDestination()
        }
    }

    /// Повторяет путь, которым AppKit ищет приёмник перетаскивания:
    /// hit-test по точке и подъём по цепочке superview до зарегистрированного view.
    private func logDragDestination() {
        guard let content = panel.contentView else { return }
        let probes = ["центр": NSPoint(x: content.bounds.midX, y: content.bounds.midY),
                      "строка списка": NSPoint(x: content.bounds.midX, y: content.bounds.maxY - 130)]
        for (name, point) in probes {
            var view = content.hitTest(point)
            var found: NSView?
            while let current = view {
                if !current.registeredDraggedTypes.isEmpty { found = current; break }
                view = current.superview
            }
            NSLog("PSTE: приёмник для «\(name)» → \(found.map { String(describing: type(of: $0)) } ?? "НЕ НАЙДЕН")")
        }
    }

    // MARK: - Закрытие по клику мимо окна

    private func startMouseMonitors() {
        stopMouseMonitors()
        // Ловим именно отпускание кнопки: если пользователь тащит файл на полку,
        // кнопка отпускается уже над панелью — и она не закроется.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        ) { [weak self] _ in
            self?.hideIfClickOutside()
        }
    }

    private func stopMouseMonitors() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
    }

    private func hideIfClickOutside() {
        // Элемент тащат из полки наружу — отпускание кнопки над Finder
        // завершает перетаскивание, а не закрывает окно.
        guard !DragState.shared.isDraggingOut else { return }
        let point = NSEvent.mouseLocation
        guard !panel.frame.insetBy(dx: -4, dy: -4).contains(point) else { return }
        guard !anchorFrame().insetBy(dx: -4, dy: -4).contains(point) else { return }
        hide(reason: "клик мимо окна в \(point)")
    }
}

// MARK: - Доступ к контроллеру из SwiftUI

private struct PanelControllerKey: EnvironmentKey {
    static let defaultValue: PanelController? = nil
}

extension EnvironmentValues {
    var panelController: PanelController? {
        get { self[PanelControllerKey.self] }
        set { self[PanelControllerKey.self] = newValue }
    }
}

extension Notification.Name {
    static let panelDidShow = Notification.Name("PSTE.panelDidShow")
}
