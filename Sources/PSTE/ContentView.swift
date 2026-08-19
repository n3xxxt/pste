import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var dropState: DropState
    @Environment(\.panelController) private var panel

    @AppStorage("pasteDirectly") private var pasteDirectly = true
    @AppStorage("closeAfterCopy") private var closeAfterCopy = true
    @AppStorage("historyLimitSetting") private var historyLimitSetting = 200
    @AppStorage("captureScreenshots") private var captureScreenshots = true
    @AppStorage("moveScreenshots") private var moveScreenshots = true
    @AppStorage("captureEmulator") private var captureEmulator = true

    @State private var selection: UUID?
    @State private var hovered: UUID?
    /// Список подкручивается к выбранной строке только после клавиатуры.
    @State private var followSelection = false
    @State private var hotKey = HotKeyPreference.current
    @State private var hotKeyRegistered = HotKeyPreference.isRegistered
    @State private var isRecordingHotKey = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: PanelController.width, height: PanelController.height)
        .background { VisualEffectBackground() }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .overlay { dropOverlay }
        .overlay { hotKeyOverlay }
        .onReceive(NotificationCenter.default.publisher(for: .hotKeyPreferenceChanged)) { _ in
            hotKey = HotKeyPreference.current
            hotKeyRegistered = HotKeyPreference.isRegistered
        }
        .onReceive(NotificationCenter.default.publisher(for: .hotKeyRegistrationChanged)) { _ in
            hotKeyRegistered = HotKeyPreference.isRegistered
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelDidShow)) { _ in
            searchFocused = true
            selection = store.visible.first?.id
        }
        .onChange(of: store.query) { _, _ in selection = store.visible.first?.id }
        .onChange(of: store.filter) { _, _ in selection = store.visible.first?.id }
    }

    // MARK: - Шапка

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12, weight: .medium))

                TextField("Поиск по буферу…", text: $store.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                    .onKeyPress(phases: .down) { press in handleKey(press) }

                if !store.query.isEmpty {
                    Button {
                        store.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Store.Filter.allCases) { filter in
                        FilterChip(filter: filter, isActive: store.filter == filter) {
                            store.filter = filter
                        }
                    }
                }
                .padding(.horizontal, 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Список

    @ViewBuilder
    private var content: some View {
        let items = store.visible
        if items.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            ClipRow(
                                item: item,
                                index: index,
                                isSelected: selection == item.id,
                                isHovered: hovered == item.id,
                                onHover: { inside in
                                    hovered = inside ? item.id : (hovered == item.id ? nil : hovered)
                                    // Наведение сразу выбирает строку — так кнопки
                                    // не пропадают, пока курсор идёт к ним.
                                    if inside { selection = item.id }
                                },
                                onActivate: { activate(item) },
                                onSelect: { selection = item.id },
                                makeMenu: { menu(for: item) }
                            )
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .onChange(of: selection) { _, new in
                    // Подкручиваем список только за клавиатурой: иначе список
                    // прыгал бы под курсором при каждом наведении.
                    guard let new, followSelection else { return }
                    followSelection = false
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: store.query.isEmpty ? "tray.and.arrow.down" : "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(store.query.isEmpty ? "Пока пусто" : "Ничего не найдено")
                .font(.system(size: 13, weight: .medium))
            if store.query.isEmpty {
                Text("Копируйте что угодно — оно появится здесь.\nПеретащите файлы в это окно или на иконку\nв строке меню. Вызов полки — \(hotKey.display).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Подвал

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(store.items.count) \(Plural.items(store.items.count))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if store.visible.count > 1 {
                dragAllHandle
            }

            Spacer()

            Text("\(hotKey.display) вызов · ↩ вставить")
                .font(.system(size: 11))
                .foregroundStyle(hotKeyRegistered ? Color.primary.opacity(0.35) : Color.orange)
                .help(hotKeyRegistered
                      ? "Сочетание для вызова полки — можно изменить в настройках"
                      : "Сочетание занято другой программой — задайте другое в настройках")

            Menu {
                settingsMenu
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Потянув за неё, пользователь вытаскивает наружу весь текущий список.
    private var dragAllHandle: some View {
        HStack(spacing: 3) {
            Image(systemName: "square.stack.3d.up.fill").font(.system(size: 9, weight: .semibold))
            Text("тащить всё").font(.system(size: 10.5, weight: .medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .foregroundStyle(.secondary)
        .overlay { DragAllSource(items: store.visible) }
        .help("Потяните, чтобы вытащить все элементы списка сразу")
    }

    @ViewBuilder
    private var settingsMenu: some View {
        Button("Сочетание вызова: \(hotKey.display)…") { startRecordingHotKey() }
        if !hotKeyRegistered {
            Text("Сочетание \(hotKey.display) занято другой программой")
        }
        if hotKey != .fallback {
            Button("Вернуть \(HotKeyPreference.fallback.display)") {
                HotKeyPreference.reset()
                hotKey = .fallback
            }
        }

        Divider()

        Toggle("Скриншоты сразу в буфер обмена", isOn: $captureScreenshots)
        Toggle("Не оставлять снимки на рабочем столе", isOn: $moveScreenshots)
            .disabled(!captureScreenshots)
        Toggle("Забирать снимки и видео из Android-эмулятора", isOn: $captureEmulator)
            .disabled(!captureScreenshots)
        Toggle("Вставлять сразу в активное окно", isOn: $pasteDirectly)
        Toggle("Закрывать окно после копирования", isOn: $closeAfterCopy)
        Toggle("Запускать при входе в систему", isOn: Binding(
            get: { LoginItem.isEnabled },
            set: { LoginItem.isEnabled = $0 }
        ))

        Divider()

        Picker("Хранить записей", selection: $historyLimitSetting) {
            Text("50").tag(50)
            Text("100").tag(100)
            Text("200").tag(200)
            Text("500").tag(500)
            Text("Без ограничения").tag(0)
        }
        .onChange(of: historyLimitSetting) { _, new in store.historyLimit = new }

        Divider()

        if !Paster.isTrusted {
            Button("Разрешить автовставку…") { Paster.requestAccessIfNeeded() }
        }
        Button("Очистить историю") { store.clear(keepPinned: true) }
        Button("Очистить всё, включая закреплённое") { store.clear(keepPinned: false) }

        Divider()

        Button("Выйти из PSTE") { NSApp.terminate(nil) }
    }

    // MARK: - Запись сочетания вызова

    @ViewBuilder
    private var hotKeyOverlay: some View {
        if isRecordingHotKey {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                VStack(spacing: 12) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(Color.accentColor)
                    Text("Нажмите новое сочетание")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Нужен хотя бы один модификатор (⌘, ⌥, ⌃, ⇧)\nили клавиша F1–F20")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                    Text("Сейчас: \(hotKey.display)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    Text("Esc — отмена")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                .padding(24)

                HotKeyRecorder(
                    onCapture: { preference in
                        HotKeyPreference.save(preference)
                        hotKey = preference
                        finishRecordingHotKey()
                    },
                    onCancel: { finishRecordingHotKey() }
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .transition(.opacity)
        }
    }

    private func startRecordingHotKey() {
        searchFocused = false
        isRecordingHotKey = true
    }

    private func finishRecordingHotKey() {
        isRecordingHotKey = false
        searchFocused = true
    }

    // MARK: - Подсветка при перетаскивании

    @ViewBuilder
    private var dropOverlay: some View {
        if dropState.isTargeted {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [7, 5]))
                .background(Color.accentColor.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 30, weight: .medium))
                        Text("Отпустите — положим на полку")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    // MARK: - Действия

    private func activate(_ item: ClipItem) {
        selection = item.id
        panel?.activate(item)
    }

    private func activateSelected() {
        guard let id = selection, let item = store.visible.first(where: { $0.id == id }) else { return }
        activate(item)
    }

    /// Единая клавиатурная логика: стрелки, Enter, Tab, ⌘⌫ и ⌘1…⌘9.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .downArrow:
            move(1)
            return .handled
        case .upArrow:
            move(-1)
            return .handled
        case .return:
            activateSelected()
            return .handled
        case .tab:
            cycleFilter()
            return .handled
        case .delete, .deleteForward:
            guard press.modifiers.contains(.command) else { return .ignored }
            deleteSelected()
            return .handled
        default:
            guard press.modifiers.contains(.command),
                  let number = Int(press.characters), (1...9).contains(number)
            else { return .ignored }
            let items = store.visible
            guard items.indices.contains(number - 1) else { return .handled }
            activate(items[number - 1])
            return .handled
        }
    }

    private func deleteSelected() {
        guard let id = selection, let item = store.visible.first(where: { $0.id == id }) else { return }
        let items = store.visible
        let index = items.firstIndex { $0.id == id } ?? 0
        store.remove(item)
        let rest = store.visible
        selection = rest.indices.contains(index) ? rest[index].id : rest.last?.id
    }

    private func move(_ delta: Int) {
        let items = store.visible
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selection } ?? -1
        let next = min(max(current + delta, 0), items.count - 1)
        followSelection = true
        selection = items[next].id
    }

    private func cycleFilter() {
        let all = Store.Filter.allCases
        let index = all.firstIndex(of: store.filter) ?? 0
        store.filter = all[(index + 1) % all.count]
    }

    // MARK: - Контекстное меню

    private func menu(for item: ClipItem) -> NSMenu {
        let menu = ClosureMenu()
        menu.addAction("Скопировать") { store.copyToPasteboard(item) }
        if Paster.isTrusted {
            menu.addAction("Скопировать и вставить") { panel?.activate(item) }
        }
        menu.addItem(.separator())

        switch item.kind {
        case .files:
            menu.addAction("Показать в Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(item.urls)
            }
            menu.addAction("Открыть") {
                item.urls.forEach { NSWorkspace.shared.open($0) }
            }
        case .link:
            menu.addAction("Открыть ссылку") {
                if let text = item.text, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    NSWorkspace.shared.open(url)
                }
            }
        case .image:
            menu.addAction("Сохранить как…") { saveImage(item) }
            menu.addAction("Открыть в просмотре") {
                if let url = item.blobURL { NSWorkspace.shared.open(url) }
            }
        default:
            break
        }
        menu.addItem(.separator())
        menu.addAction(item.pinned ? "Открепить" : "Закрепить") { store.togglePin(item) }
        menu.addAction("Удалить") {
            store.remove(item)
            selection = store.visible.first?.id
        }
        return menu
    }

    private func saveImage(_ item: ClipItem) {
        guard let source = item.blobURL else { return }
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = source.lastPathComponent
        savePanel.allowedContentTypes = [.png]
        savePanel.level = .modalPanel
        if savePanel.runModal() == .OK, let target = savePanel.url {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: source, to: target)
        }
    }
}

// MARK: - Чип фильтра

private struct FilterChip: View {
    let filter: Store.Filter
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isActive {
                    Image(systemName: filter.symbol).font(.system(size: 10, weight: .semibold))
                }
                Text(filter.title).font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(
                Capsule().fill(isActive ? Color.accentColor : Color.primary.opacity(0.07))
            )
            .foregroundStyle(isActive ? Color.white : Color.primary.opacity(0.85))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Материал окна

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - NSMenu с замыканиями

final class ClosureMenu: NSMenu {
    private var handlers: [Handler] = []

    final class Handler: NSObject {
        let block: () -> Void
        init(_ block: @escaping () -> Void) { self.block = block }
        @objc func fire() { block() }
    }

    func addAction(_ title: String, _ block: @escaping () -> Void) {
        let handler = Handler(block)
        handlers.append(handler)
        let item = NSMenuItem(title: title, action: #selector(Handler.fire), keyEquivalent: "")
        item.target = handler
        addItem(item)
    }
}
