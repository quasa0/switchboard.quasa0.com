#!/bin/bash
set -euo pipefail
SWITCHBOARD_SIGN_APP="$1"
SWITCHBOARD_SIGN_IDENTITY="${2:--}"
SWITCHBOARD_SIGN_ARGS=(--force --sign "$SWITCHBOARD_SIGN_IDENTITY" --options runtime)
if [ "$SWITCHBOARD_SIGN_IDENTITY" = - ]; then
  SWITCHBOARD_SIGN_ARGS+=(--entitlements "$(dirname "$0")/../config/ad-hoc.entitlements.plist")
fi
SWITCHBOARD_SIGN_FRAMEWORK="$SWITCHBOARD_SIGN_APP/Contents/Frameworks/Sparkle.framework"
# Sign from the inside out with the app's identity. Nested installer processes
# need matching signatures when the host uses hardened runtime library validation.
for SWITCHBOARD_SIGN_COMPONENT in \
  "$SWITCHBOARD_SIGN_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
  "$SWITCHBOARD_SIGN_FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
  "$SWITCHBOARD_SIGN_FRAMEWORK/Versions/B/Autoupdate" \
  "$SWITCHBOARD_SIGN_FRAMEWORK/Versions/B/Updater.app" \
  "$SWITCHBOARD_SIGN_FRAMEWORK" "$SWITCHBOARD_SIGN_APP"; do
  codesign "${SWITCHBOARD_SIGN_ARGS[@]}" "$SWITCHBOARD_SIGN_COMPONENT"
done
codesign --verify --deep --strict "$SWITCHBOARD_SIGN_APP"
