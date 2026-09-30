#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/version.sh
SWITCHBOARD_BUILD_ARGS=(-c release -Xswiftc -file-prefix-map -Xswiftc "$PWD=." -Xswiftc -debug-prefix-map -Xswiftc "$PWD=.")
case "${SWITCHBOARD_ARCH:-native}" in
  native) ;;
  universal) SWITCHBOARD_BUILD_ARGS+=(--arch arm64 --arch x86_64) ;;
  arm64|x86_64) SWITCHBOARD_BUILD_ARGS+=(--arch "$SWITCHBOARD_ARCH") ;;
  *) printf 'Use SWITCHBOARD_ARCH=native, universal, arm64, or x86_64.\n' >&2; exit 1 ;;
esac
swift build "${SWITCHBOARD_BUILD_ARGS[@]}"
SWITCHBOARD_BIN_DIR=$(swift build "${SWITCHBOARD_BUILD_ARGS[@]}" --show-bin-path)
SWITCHBOARD_APP="$PWD/dist/Switchboard.app"
if [ -d "$SWITCHBOARD_APP" ]; then rm -rf "$SWITCHBOARD_APP"; fi
mkdir -p "$SWITCHBOARD_APP/Contents/MacOS" "$SWITCHBOARD_APP/Contents/Resources" "$SWITCHBOARD_APP/Contents/Frameworks"
cp "$SWITCHBOARD_BIN_DIR/Switchboard" "$SWITCHBOARD_APP/Contents/MacOS/Switchboard"
strip -S "$SWITCHBOARD_APP/Contents/MacOS/Switchboard"
ditto "$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$SWITCHBOARD_APP/Contents/Frameworks/Sparkle.framework"
SWITCHBOARD_UPDATE_KEY=$(cat config/update-public-key.txt)
cat > "$SWITCHBOARD_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Switchboard</string>
<key>CFBundleIdentifier</key><string>com.quasa0.switchboard</string>
<key>CFBundleName</key><string>Switchboard</string>
<key>CFBundleDisplayName</key><string>Switchboard</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$SWITCHBOARD_VERSION</string>
<key>CFBundleVersion</key><string>$SWITCHBOARD_BUILD</string>
<key>CFBundleIconFile</key><string>Switchboard.icns</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>SUFeedURL</key><string>https://switchboard.quasa0.com/appcast.xml</string>
<key>SUPublicEDKey</key><string>$SWITCHBOARD_UPDATE_KEY</string>
<key>SUEnableAutomaticChecks</key><false/>
<key>SUAllowsAutomaticUpdates</key><false/>
<key>SUSendProfileInfo</key><false/>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
<key>SURequireSignedFeed</key><true/>
<key>SUSignedFeedFailureExpirationInterval</key><integer>0</integer>
</dict></plist>
PLIST
if [ -f scripts/icon.swift ]; then
  swift scripts/icon.swift "$SWITCHBOARD_APP/Contents/Resources/Switchboard.icns"
fi
cp LICENSE "$SWITCHBOARD_APP/Contents/Resources/LICENSE"
cp .build/checkouts/Sparkle/LICENSE "$SWITCHBOARD_APP/Contents/Resources/Sparkle-LICENSE"
SWITCHBOARD_IDENTITY="${SWITCHBOARD_SIGNING_IDENTITY:--}"
if [ -z "${SWITCHBOARD_SIGNING_IDENTITY+x}" ]; then
  SWITCHBOARD_DETECTED=$(security find-identity -v -p codesigning | sed -n 's/.*) \([A-F0-9]\{40\}\) "Apple Development:.*/\1/p' | awk 'NR == 1 { print }')
  if [ -n "$SWITCHBOARD_DETECTED" ]; then SWITCHBOARD_IDENTITY="$SWITCHBOARD_DETECTED"; fi
fi
bash scripts/sign-app.sh "$SWITCHBOARD_APP" "$SWITCHBOARD_IDENTITY"
printf 'Built: %s\n' "$SWITCHBOARD_APP"
