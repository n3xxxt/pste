import AppKit
import SwiftUI

/// Прозрачный слой поверх строки списка: клик, наведение, контекстное меню
/// и — главное — вытаскивание элемента наружу (в Finder, редактор, мессенджер).
/// SwiftUI-овый `.onDrag` умеет отдавать только один объект, поэтому для набора
/// файлов используется полноценная AppKit-сессия перетаскивания.
final class DragSourceView: NSView, NSDraggingSource {
    /// Обычно один элемент (строка списка), но может быть и пачка —
    /// тогда наружу уезжает вся полка разом.
    var items: [ClipItem] = []
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var makeMenu: (() -> NSMenu)?
    var onDragStarted: (() -> Void)?

    private var mouseDownPoint: NSPoint?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 5 else { return }
        mouseDownPoint = nil
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if ProcessInfo.processInfo.environment["PSTE_DEBUG"] != nil {
            NSLog("PSTE: клик по слою строки, рамка в окне = \(convert(bounds, to: nil))")
        }
        guard mouseDownPoint != nil else { return }
        mouseDownPoint = nil
        if event.clickCount >= 2, let onDoubleClick {
            onDoubleClick()
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = makeMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: - Перетаскивание наружу

    private func beginDrag(with event: NSEvent) {
        let dragItems = items.flatMap { draggingItems(for: $0) }
        guard !dragItems.isEmpty else { return }
        onDragStarted?()
        beginDraggingSession(with: dragItems, event: event, source: self)
    }

    private func draggingItems(for item: ClipItem) -> [NSDraggingItem] {
        switch item.kind {
        case .files:
            let urls = item.urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            return urls.enumerated().map { index, url in
                let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                let side: CGFloat = 48
                let origin = NSPoint(x: bounds.midX - side / 2 + CGFloat(index) * 6,
                                     y: bounds.midY - side / 2 - CGFloat(index) * 6)
                dragItem.setDraggingFrame(NSRect(origin: origin, size: NSSize(width: side, height: side)),
                                          contents: icon)
                return dragItem
            }

        case .image:
            guard let url = item.blobURL, FileManager.default.fileExists(atPath: url.path) else { return [] }
            let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
            let preview = NSImage(contentsOf: url)?.thumbnail(maxSide: 96) ?? NSImage()
            let size = preview.size == .zero ? NSSize(width: 64, height: 64) : preview.size
            dragItem.setDraggingFrame(NSRect(x: bounds.midX - size.width / 2,
                                             y: bounds.midY - size.height / 2,
                                             width: size.width, height: size.height),
                                      contents: preview)
            return [dragItem]

        case .link:
            let raw = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw) else { return textDragItems(raw) }
            let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
            decorate(dragItem, with: raw)
            return [dragItem]

        case .richText:
            if let url = item.blobURL, let data = try? Data(contentsOf: url),
               let attributed = NSAttributedString(rtf: data, documentAttributes: nil) {
                let dragItem = NSDraggingItem(pasteboardWriter: attributed)
                decorate(dragItem, with: attributed.string)
                return [dragItem]
            }
            return textDragItems(item.text ?? "")

        case .text, .color:
            return textDragItems(item.text ?? "")
        }
    }

    private func textDragItems(_ string: String) -> [NSDraggingItem] {
        guard !string.isEmpty else { return [] }
        let dragItem = NSDraggingItem(pasteboardWriter: string as NSString)
        decorate(dragItem, with: string)
        return [dragItem]
    }

    /// Рисует «бумажку» с текстом, которая летит за курсором.
    private func decorate(_ dragItem: NSDraggingItem, with string: String) {
        let preview = String(string.prefix(80)).replacingOccurrences(of: "\n", with: " ")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor
        ]
        let textSize = (preview as NSString).size(withAttributes: attributes)
        let size = NSSize(width: min(textSize.width + 20, 280), height: 26)

        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        NSColor.controlBackgroundColor.withAlphaComponent(0.95).setFill()
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
        (preview as NSString).draw(in: rect.insetBy(dx: 10, dy: 5), withAttributes: attributes)
        image.unlockFocus()

        dragItem.setDraggingFrame(NSRect(x: bounds.midX - size.width / 2,
                                         y: bounds.midY - size.height / 2,
                                         width: size.width, height: size.height),
                                  contents: image)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : [.copy, .link, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        DragState.shared.isDraggingOut = true
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        // Небольшая задержка: отпускание кнопки прилетает в глобальный монитор
        // уже после завершения сессии, и полка не должна из-за него закрыться.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            DragState.shared.isDraggingOut = false
        }
    }
}

/// Общий флаг: из полки прямо сейчас что-то тащат наружу.
/// Пока он поднят, окно не закрывается по отпусканию кнопки мимо себя.
final class DragState {
    static let shared = DragState()
    var isDraggingOut = false
}

// MARK: - Мост в SwiftUI

struct DragSource: NSViewRepresentable {
    let item: ClipItem
    var onClick: () -> Void
    var onHover: (Bool) -> Void
    var makeMenu: () -> NSMenu
    var onDragStarted: () -> Void

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: DragSourceView) {
        view.items = [item]
        view.onClick = onClick
        view.onHover = onHover
        view.makeMenu = makeMenu
        view.onDragStarted = onDragStarted
    }
}

/// Ручка «утащить всё сразу»: одним движением вытаскивает наружу все
/// элементы, которые сейчас видны в списке.
struct DragAllSource: NSViewRepresentable {
    let items: [ClipItem]

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.items = items
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.items = items
    }
}
