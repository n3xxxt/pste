import AppKit
import SwiftUI

struct ClipRow: View {
    @EnvironmentObject private var store: Store

    let item: ClipItem
    let index: Int
    let isSelected: Bool
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onActivate: () -> Void
    let onSelect: () -> Void
    let makeMenu: () -> NSMenu

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(item.kind == .image || item.kind == .files ? 1 : 2)
                        .truncationMode(.tail)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                    Text(item.subtitle)
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .overlay {
                DragSource(
                    item: item,
                    onClick: onActivate,
                    onHover: onHover,
                    makeMenu: { onSelect(); return makeMenu() },
                    onDragStarted: onSelect
                )
            }

            // Кнопки справа живут вне AppKit-слоя, поэтому наведение на них
            // отслеживаем отдельно — иначе курсор «теряет» строку по дороге.
            trailing
                .onHover { inside in onHover(inside) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(background)
        }
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.95) }
        if isHovered { return Color.primary.opacity(0.07) }
        return .clear
    }

    // MARK: - Иконка / превью

    @ViewBuilder
    private var icon: some View {
        ZStack {
            if let thumb = store.thumbnail(for: item) {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else if item.kind == .color, let hex = item.text, let color = NSColor(hexString: hex) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: color))
                    .frame(width: 30, height: 30)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.15))
                    }
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.2) : Color.primary.opacity(0.07))
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: item.kind.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    }
            }
        }
        .frame(width: 34, height: 34)
        .overlay(alignment: .topLeading) {
            if item.isShelf {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(2.5)
                    .background(Circle().fill(Color.orange))
                    .offset(x: -3, y: -3)
            }
        }
    }

    // MARK: - Правый край

    private var trailing: some View {
        Group {
            if showsActions {
                HStack(spacing: 2) {
                    IconButton(symbol: item.pinned ? "pin.fill" : "pin",
                               tint: isSelected ? .white : .secondary,
                               help: item.pinned ? "Открепить" : "Закрепить") {
                        debugTap("закрепление")
                        store.togglePin(item)
                    }
                    IconButton(symbol: "trash",
                               tint: isSelected ? .white : .secondary,
                               help: "Удалить из истории") {
                        debugTap("корзина")
                        store.remove(item)
                    }
                }
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    if item.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                    Text(Fmt.ago(item.date))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: 54, alignment: .trailing)
        .contentShape(Rectangle())
    }

    /// Кнопки показываем и при наведении, и на выбранной строке: пока курсор
    /// едет к корзине, строка уже выбрана — и кнопки не исчезают под курсором.
    private var showsActions: Bool { isHovered || isSelected }

    private func debugTap(_ name: String) {
        guard ProcessInfo.processInfo.environment["PSTE_DEBUG"] != nil else { return }
        NSLog("PSTE: нажата кнопка «\(name)»")
    }

}

/// Кнопка действия в строке: подсвечивается под курсором, чтобы было понятно,
/// что она нажимается.
private struct IconButton: View {
    let symbol: String
    let tint: Color
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .background {
                    Circle().fill(Color.primary.opacity(isHovered ? 0.18 : 0))
                }
                .contentShape(Rectangle())
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}
