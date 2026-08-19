#!/bin/bash
# Сборка PSTE.app. Использование:
#   ./build.sh            — собрать в ./build/PSTE.app
#   ./build.sh --install  — собрать, положить в /Applications и запустить
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="PSTE"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "▸ Компиляция (release)…"
cd "$ROOT"
swift build -c release --disable-sandbox

BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

echo "▸ Сборка бандла…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

echo "▸ Иконка…"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$ROOT/Tools/make-icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>PSTE</string>
    <key>CFBundleDisplayName</key>     <string>PSTE</string>
    <key>CFBundleExecutable</key>      <string>PSTE</string>
    <key>CFBundleIdentifier</key>      <string>dev.pste.app</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSSupportsAutomaticTermination</key> <false/>
    <key>NSHumanReadableCopyright</key><string>Локальный менеджер буфера обмена</string>
</dict>
</plist>
PLIST

echo "▸ Подпись (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "✓ Готово: $APP"

if [[ "${1:-}" == "--install" ]]; then
    TARGET="/Applications/$APP_NAME.app"
    if [[ ! -w /Applications ]]; then
        TARGET="$HOME/Applications/$APP_NAME.app"
        mkdir -p "$HOME/Applications"
    fi
    echo "▸ Установка в ${TARGET}"
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 0.5
    rm -rf "$TARGET"
    cp -R "$APP" "$TARGET"
    open "$TARGET"
    echo "✓ Запущено. Иконка — в строке меню, хоткей ⌘⇧V."
fi
