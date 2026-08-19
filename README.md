# PSTE

A clipboard manager and a drag & drop shelf in one macOS menu bar app.
Everything stays on your machine — no cloud, no account, no network calls.

[Русская версия](README.ru.md)

![PSTE panel](docs/panel.png)

## Why another clipboard manager

Most of them do history well but stop there. PSTE also acts as a shelf: drop files
on the menu bar icon, walk to another app, drag them out. And it quietly picks up
the things that usually litter your desktop — screen captures and Android emulator
recordings — putting them straight into the clipboard instead.

## Features

**Clipboard history**
- Text, rich text, links, HEX colors, images, files.
- Search, filters by type, pinning, automatic trimming (50…unlimited entries).
- Passwords are skipped: anything marked `org.nspasteboard.ConcealedType`
  (1Password, Bitwarden, Keychain and friends) never touches the history.

**Shelf — drag & drop both ways**
- Drop files **onto the menu bar icon** — the shelf springs open under the cursor.
- Drop anything **into the open window** — it lands on the shelf with an orange badge.
- Drag an item **out of the window** into Finder, an editor or a chat. Files leave as
  a batch, images and text as themselves, links as links.
- “Drag all” in the footer pulls the whole visible list out in one gesture.
- Images dragged from a browser and mail attachments arrive as file promises: the file
  is copied into PSTE’s own storage, so it still works after the source window is gone.

**Screen captures**
- A new screenshot goes to the clipboard and into the history automatically.
- Your desktop stays clean: the file moves into PSTE’s storage under its original name,
  ready to be dragged anywhere or saved via “Save as…”. Turn the option off and the
  file stays where macOS put it.
- macOS settings are never rewritten — with PSTE closed, screenshots behave as usual.

**Android emulator**
- Screenshots and screen recordings from the emulator (camera button, *Record and
  Playback*, or anything saved into that folder) are picked up automatically: an image
  lands in the clipboard as an image, a video as a file ready for ⌘V into a chat,
  Finder or an editor.
- No setup required. While PSTE runs, the emulator’s save folder
  (`com.android.Emulator` → `set.savePath`) points at its own directory, so nothing
  appears on the desktop. On quit the previous path is restored.
- Recordings are only taken once the file stops growing, so a half-written video
  never ends up on the shelf.

## Keyboard

| Action | Keys |
|---|---|
| Show / hide the shelf | ⌥⌘V, or click the menu bar icon |
| Move through the list | ↑ / ↓ |
| Paste the selected item | ↩ |
| Quick paste | ⌘1 … ⌘9 |
| Delete an entry | ⌘⌫ |
| Cycle filters | ⇥ |
| Clear search / close | Esc |
| Item menu | right click on a row |

The shortcut is configurable: **gear → “Сочетание вызова…”**, then press the combination
you want (at least one modifier, or F1–F20). It is registered globally through Carbon, so
it needs no accessibility permission, and the app tells you when the combination is
already taken by someone else. The default is ⌥⌘V rather than ⌘⇧V on purpose — the
latter is “Paste and Match Style” in most apps, and grabbing it globally would take that
away everywhere.

## Install

Requires macOS 14+ and Xcode 15+ to build.

```bash
git clone https://github.com/n3xxxt/pste.git
cd pste
./build.sh --install   # builds, installs into /Applications and launches
```

`./build.sh` alone leaves the bundle in `./build/PSTE.app`.

The app is signed ad-hoc, so the first launch from Finder may need
right click → **Open**. Direct paste (pressing ⌘V for you) needs
**System Settings → Privacy & Security → Accessibility**; without it an item is
simply copied to the clipboard.

## Settings

The gear in the bottom right corner: direct paste, close after copying, launch at
login, screenshot capture, emulator capture, history limit, clearing.

## Debugging

```bash
PSTE_DEBUG=1 /Applications/PSTE.app/Contents/MacOS/PSTE
```

Logs where the panel was placed, why it closed, which drag destination AppKit
resolves inside the window and which row buttons were pressed.

## How it is put together

Plain SwiftUI + AppKit, Swift Package Manager, no third-party dependencies.

| File | Responsibility |
|---|---|
| `Model.swift` | history item, blob storage, formatting |
| `ClipReader.swift` | single `NSPasteboard` parser for clipboard and drag & drop |
| `ClipboardMonitor.swift` | polls the system pasteboard `changeCount` |
| `CaptureWatcher.swift` | watches screenshot and emulator folders |
| `EmulatorCapture.swift` | redirects the emulator’s save folder |
| `Store.swift` | history, dedup, search, persistence, previews |
| `PanelController.swift` | floating panel, placement, direct paste |
| `StatusItemController.swift` | menu bar icon and drops onto it |
| `DragSourceView.swift` | dragging items out |
| `DropCatcherView.swift` | accepting drops, including file promises |
| `ContentView.swift`, `ClipRow.swift` | interface |

Data lives in `~/Library/Application Support/PSTE`.

## License

MIT — see [LICENSE](LICENSE).
