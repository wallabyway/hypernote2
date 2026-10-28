#!/usr/bin/env bash
# Builds a release Hypernote2.app (menu bar app + WKWebView host) into ./build.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Hypernote2.app"
SWIFT_FLAGS=(${SWIFT_BUILD_FLAGS:-})

swift build -c release ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}
BIN="$(swift build -c release ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} --show-bin-path)/Hypernote2"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Hypernote2"
cp -R web "$APP/Contents/Resources/web"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Hypernote2</string>
  <key>CFBundleDisplayName</key><string>Hypernote2</string>
  <key>CFBundleIdentifier</key><string>com.hypernote2.app</string>
  <key>CFBundleExecutable</key><string>Hypernote2</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Hypernote2 records your microphone so it can transcribe your meetings.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Hypernote2 records meeting audio so it can transcribe the other participants.</string>
</dict></plist>
PLIST

# Ad-hoc signature keeps microphone/screen permissions stable between launches.
codesign --force --deep --sign - "$APP"

echo "Built $APP"
du -sh "$APP"
