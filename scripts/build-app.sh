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
  <key>CFBundleShortVersionString</key><string>0.3.0</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Hypernote2 records your microphone so it can transcribe your meetings.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Hypernote2 records meeting audio so it can transcribe the other participants.</string>
</dict></plist>
PLIST

# Sign with a stable identity so macOS privacy grants (Microphone, System Audio Recording) survive
# rebuilds. Ad-hoc signatures change every build, which silently revokes those permissions.
IDENTITY="Hypernote2 Local Signing"
if ! security find-identity -p codesigning | grep -q "$IDENTITY"; then
  ./scripts/create-signing-cert.sh || true
fi
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --deep --options runtime --sign "$IDENTITY" \
    --entitlements Resources/Hypernote2.entitlements "$APP"
else
  echo "warning: signing ad-hoc; permissions will reset on every rebuild" >&2
  codesign --force --deep --sign - --entitlements Resources/Hypernote2.entitlements "$APP"
fi

echo "Built $APP"
du -sh "$APP"

# --install: replace /Applications/Hypernote2.app with this build and relaunch it.
if [[ "${1:-}" == "--install" ]]; then
  pkill -x Hypernote2 || true
  sleep 1
  rm -rf /Applications/Hypernote2.app
  ditto "$APP" /Applications/Hypernote2.app
  open /Applications/Hypernote2.app
  echo "Installed /Applications/Hypernote2.app"
fi
