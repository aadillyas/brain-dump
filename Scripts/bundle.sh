#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product BrainDump
BIN_DIR="$(swift build -c release --product BrainDump --show-bin-path)"
APP="dist/BrainDump.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN_DIR/BrainDump" "$APP/Contents/MacOS/BrainDump"
cp -R "$BIN_DIR/llama.framework" "$APP/Contents/Frameworks/"

for b in "$BIN_DIR"/*.bundle; do
  [ -e "$b" ] || continue
  cp -R "$b" "$APP/Contents/Resources/"
  echo "copied resource bundle $(basename "$b")"
done

ICONSET="$(mktemp -d)/AppIcon.iconset"
swift Scripts/make-icon.swift Assets/icon-source.png "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>BrainDump</string>
  <key>CFBundleIdentifier</key><string>app.braindump.BrainDump</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleName</key><string>Brain Dump</string>
  <key>CFBundleDisplayName</key><string>Brain Dump</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key><string>Brain Dump transcribes your voice on this Mac while you talk through your morning dump.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>Brain Dump creates reminders from the tasks and reminders you approve.</string>
  <key>NSRemindersUsageDescription</key><string>Brain Dump creates reminders from the tasks and reminders you approve.</string>
</dict>
</plist>
PLIST

EXE="$APP/Contents/MacOS/BrainDump"
if ! otool -l "$EXE" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE"
fi

codesign --force --sign - "$APP/Contents/Frameworks/llama.framework"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
rm -f dist/BrainDump.zip
ditto -c -k --keepParent "$APP" dist/BrainDump.zip
echo "$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
