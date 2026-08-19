import AppKit
import SwiftUI

/// Корневой view окна: принимает перетаскивание извне и разбирает
/// NSPasteboard тем же кодом, что и монитор буфера обмена.
/// Важно, что это именно предок SwiftUI-иерархии — AppKit ищет цель
/// перетаскивания вверх по цепочке superview, а не среди соседей.
class DropCatcherView: NSView {
    var onTargeted: ((Bool) -> Void)?
    var onDrop: ((NSPasteboard) -> Bool)?

    /// Файлы, полученные «обещанием» (перетаскивание картинки из браузера).
    var onPromisedFiles: (([URL]) -> Void)?

    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [
            .fileURL, .URL, .string, .rtf, .rtfd, .png, .tiff, .html, .fileContents
        ]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        return types
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Перетаскивание внутри самого приложения (элемент тащат наружу)
        // не должно подсвечивать полку как цель.
        guard sender.draggingSource == nil else { return [] }
        onTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingSource == nil ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargeted?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargeted?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargeted?(false)
        guard sender.draggingSource == nil else { return false }

        if onDrop?(sender.draggingPasteboard) == true { return true }
        return receivePromisedFiles(from: sender)
    }

    /// Браузеры и почтовые клиенты отдают не готовый файл, а обещание его
    /// записать. Забираем такие файлы в свою папку, чтобы полку можно было
    /// разгрузить позже — уже после закрытия исходного окна.
    private func receivePromisedFiles(from sender: NSDraggingInfo) -> Bool {
        let receivers = sender.draggingPasteboard
            .readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]
        guard let receivers, !receivers.isEmpty else { return false }

        let destination = Blobs.droppedDirectory
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated

        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue) { url, error in
                guard error == nil else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.onPromisedFiles?([url])
                }
            }
        }
        return true
    }
}

/// Состояние подсветки окна при наведении перетаскиваемого объекта.
@MainActor
final class DropState: ObservableObject {
    @Published var isTargeted = false
}
