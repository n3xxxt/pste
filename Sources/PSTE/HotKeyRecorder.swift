import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Ловит следующее нажатие, чтобы назначить его сочетанием вызова полки.
/// Обязательно перехватывает и `performKeyEquivalent`: сочетания с ⌘ приходят
/// туда, а не в `keyDown`, и иначе улетели бы в поле поиска.
final class HotKeyRecorderView: NSView {
    var onCapture: ((HotKeyPreference) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        handle(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handle(event)
        return true
    }

    /// Модификаторы сами по себе сочетанием не считаются — ждём обычную клавишу.
    override func flagsChanged(with event: NSEvent) {}

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel?()
            return
        }
        guard let preference = HotKeyPreference.from(event: event) else {
            NSSound.beep()
            return
        }
        onCapture?(preference)
    }
}

struct HotKeyRecorder: NSViewRepresentable {
    let onCapture: (HotKeyPreference) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> HotKeyRecorderView {
        let view = HotKeyRecorderView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ view: HotKeyRecorderView, context: Context) {
        view.onCapture = onCapture
        view.onCancel = onCancel
        if view.window?.firstResponder !== view {
            view.window?.makeFirstResponder(view)
        }
    }
}
