#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Live Connections Monitor.app"
EXE="$ROOT/.build/arm64-apple-macosx/release/LiveConnectionsMonitor"

cd "$ROOT"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXE" "$APP/Contents/MacOS/LiveConnectionsMonitor"
chmod +x "$APP/Contents/MacOS/LiveConnectionsMonitor"
cp "$ROOT/Resources/ConmagIcon.icns" "$APP/Contents/Resources/ConmagIcon.icns"
cp "$ROOT/Resources/conmag-icon.png" "$APP/Contents/Resources/conmag-icon.png"
printf 'APPL????' > "$APP/Contents/PkgInfo"

/usr/libexec/PlistBuddy -c 'Clear dict' \
  -c 'Add :CFBundleDevelopmentRegion string en' \
  -c 'Add :CFBundleDisplayName string Firewall Dashboard' \
  -c 'Add :CFBundleExecutable string LiveConnectionsMonitor' \
  -c 'Add :CFBundleIconFile string ConmagIcon' \
  -c 'Add :CFBundleIdentifier string local.codex.LiveConnectionsMonitor' \
  -c 'Add :CFBundleInfoDictionaryVersion string 6.0' \
  -c 'Add :CFBundleName string Firewall Dashboard' \
  -c 'Add :CFBundlePackageType string APPL' \
  -c 'Add :CFBundleShortVersionString string 1.0' \
  -c 'Add :CFBundleVersion string 1' \
  -c 'Add :LSMinimumSystemVersion string 14.0' \
  -c 'Add :NSPrincipalClass string NSApplication' \
  "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP" >/dev/null
echo "$APP"
