import AppKit
import Carbon.HIToolbox

/// Сочетание клавиш для вызова полки: хранится в настройках и переживает перезапуск.
struct HotKeyPreference: Equatable {
    var keyCode: UInt32
    /// Маска в терминах Carbon (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    var modifiers: UInt32
    /// Готовая подпись для интерфейса, например «⇧⌘V».
    var display: String

    /// ⌥⌘V, а не ⌘⇧V: последнее почти везде занято командой «Вставить без
    /// форматирования», а глобальный перехват отобрал бы её у всех приложений.
    static let fallback = HotKeyPreference(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(cmdKey | optionKey),
        display: "⌥⌘V"
    )

    // MARK: - Хранение

    private static let keyCodeKey = "hotKeyCode"
    private static let modifiersKey = "hotKeyModifiers"
    private static let displayKey = "hotKeyDisplay"

    static var current: HotKeyPreference {
        let defaults = UserDefaults.standard
        guard let code = defaults.object(forKey: keyCodeKey) as? Int,
              let mods = defaults.object(forKey: modifiersKey) as? Int,
              let display = defaults.string(forKey: displayKey), !display.isEmpty
        else { return fallback }
        return HotKeyPreference(keyCode: UInt32(code), modifiers: UInt32(mods), display: display)
    }

    static func save(_ preference: HotKeyPreference) {
        let defaults = UserDefaults.standard
        defaults.set(Int(preference.keyCode), forKey: keyCodeKey)
        defaults.set(Int(preference.modifiers), forKey: modifiersKey)
        defaults.set(preference.display, forKey: displayKey)
        NotificationCenter.default.post(name: .hotKeyPreferenceChanged, object: nil)
    }

    static func reset() {
        save(fallback)
    }

    /// Удалось ли занять сочетание: оно может быть уже занято другой программой.
    static var isRegistered = true {
        didSet {
            guard isRegistered != oldValue else { return }
            NotificationCenter.default.post(name: .hotKeyRegistrationChanged, object: nil)
        }
    }

    // MARK: - Разбор нажатия

    /// Собирает сочетание из события. Возвращает nil, если модификаторов нет —
    /// одиночные клавиши перехватывать глобально нельзя.
    static func from(event: NSEvent) -> HotKeyPreference? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }

        let isFunctionKey = Self.functionKeyNames[event.keyCode] != nil
        guard carbon != 0 || isFunctionKey else { return nil }

        var label = ""
        if flags.contains(.control) { label += "⌃" }
        if flags.contains(.option) { label += "⌥" }
        if flags.contains(.shift) { label += "⇧" }
        if flags.contains(.command) { label += "⌘" }
        label += keyName(for: event)

        return HotKeyPreference(keyCode: UInt32(event.keyCode), modifiers: carbon, display: label)
    }

    /// Подпись берём по коду клавиши, а не по введённому символу: иначе на
    /// русской раскладке то же сочетание подписывалось бы как «⌥⌘М».
    private static func keyName(for event: NSEvent) -> String {
        if let name = functionKeyNames[event.keyCode] { return name }
        if let name = specialKeyNames[event.keyCode] { return name }
        if let name = latinNames[event.keyCode] { return name }
        return (event.charactersIgnoringModifiers ?? "").uppercased()
    }

    private static let latinNames: [UInt16: String] = [
        UInt16(kVK_ANSI_A): "A", UInt16(kVK_ANSI_B): "B", UInt16(kVK_ANSI_C): "C",
        UInt16(kVK_ANSI_D): "D", UInt16(kVK_ANSI_E): "E", UInt16(kVK_ANSI_F): "F",
        UInt16(kVK_ANSI_G): "G", UInt16(kVK_ANSI_H): "H", UInt16(kVK_ANSI_I): "I",
        UInt16(kVK_ANSI_J): "J", UInt16(kVK_ANSI_K): "K", UInt16(kVK_ANSI_L): "L",
        UInt16(kVK_ANSI_M): "M", UInt16(kVK_ANSI_N): "N", UInt16(kVK_ANSI_O): "O",
        UInt16(kVK_ANSI_P): "P", UInt16(kVK_ANSI_Q): "Q", UInt16(kVK_ANSI_R): "R",
        UInt16(kVK_ANSI_S): "S", UInt16(kVK_ANSI_T): "T", UInt16(kVK_ANSI_U): "U",
        UInt16(kVK_ANSI_V): "V", UInt16(kVK_ANSI_W): "W", UInt16(kVK_ANSI_X): "X",
        UInt16(kVK_ANSI_Y): "Y", UInt16(kVK_ANSI_Z): "Z",
        UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2",
        UInt16(kVK_ANSI_3): "3", UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5",
        UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7", UInt16(kVK_ANSI_8): "8",
        UInt16(kVK_ANSI_9): "9",
        UInt16(kVK_ANSI_Minus): "-", UInt16(kVK_ANSI_Equal): "=",
        UInt16(kVK_ANSI_LeftBracket): "[", UInt16(kVK_ANSI_RightBracket): "]",
        UInt16(kVK_ANSI_Backslash): "\\", UInt16(kVK_ANSI_Semicolon): ";",
        UInt16(kVK_ANSI_Quote): "'", UInt16(kVK_ANSI_Comma): ",",
        UInt16(kVK_ANSI_Period): ".", UInt16(kVK_ANSI_Slash): "/"
    ]

    private static let specialKeyNames: [UInt16: String] = [
        UInt16(kVK_Space): "␣",
        UInt16(kVK_Return): "↩",
        UInt16(kVK_Tab): "⇥",
        UInt16(kVK_Delete): "⌫",
        UInt16(kVK_ForwardDelete): "⌦",
        UInt16(kVK_LeftArrow): "←",
        UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑",
        UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_Home): "↖",
        UInt16(kVK_End): "↘",
        UInt16(kVK_PageUp): "⇞",
        UInt16(kVK_PageDown): "⇟",
        UInt16(kVK_ANSI_Grave): "`"
    ]

    private static let functionKeyNames: [UInt16: String] = [
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15",
        UInt16(kVK_F16): "F16", UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18",
        UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20"
    ]
}

extension Notification.Name {
    static let hotKeyPreferenceChanged = Notification.Name("PSTE.hotKeyPreferenceChanged")
    static let hotKeyRegistrationChanged = Notification.Name("PSTE.hotKeyRegistrationChanged")
}
