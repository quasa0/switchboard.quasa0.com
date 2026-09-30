#!/bin/bash
# Build distribution artifacts only. Does not install, upload, or read account stores.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/version.sh
SWITCHBOARD_SPARKLE_TOOLS=$(bash scripts/sparkle-tools.sh)
export SWITCHBOARD_ARCH=universal
# Never auto-select a personal development certificate for a public download.
export SWITCHBOARD_SIGNING_IDENTITY=-
./scripts/build.sh
SWITCHBOARD_APP="$PWD/dist/Switchboard.app"
SWITCHBOARD_ARCHS=$(lipo -archs "$SWITCHBOARD_APP/Contents/MacOS/Switchboard")
if [ "$SWITCHBOARD_ARCHS" != "x86_64 arm64" ] && [ "$SWITCHBOARD_ARCHS" != "arm64 x86_64" ]; then
  printf 'Expected a universal arm64/x86_64 binary. Got: %s\n' "$SWITCHBOARD_ARCHS" >&2
  exit 1
fi
./scripts/ui-smoke.sh "$SWITCHBOARD_APP"
SWITCHBOARD_RELEASE="$PWD/dist/releases/$SWITCHBOARD_VERSION"
mkdir -p "$SWITCHBOARD_RELEASE"
SWITCHBOARD_ZIP="Switchboard-$SWITCHBOARD_VERSION-universal.zip"
ditto -c -k --keepParent --norsrc --noextattr "$SWITCHBOARD_APP" "$SWITCHBOARD_RELEASE/$SWITCHBOARD_ZIP"
SWITCHBOARD_STAGE=$(mktemp -d "${TMPDIR:-/tmp}/switchboard-dmg.XXXXXX")
trap 'rm -rf "$SWITCHBOARD_STAGE"' EXIT
ditto --norsrc --noextattr "$SWITCHBOARD_APP" "$SWITCHBOARD_STAGE/Switchboard.app"
ln -s /Applications "$SWITCHBOARD_STAGE/Applications"
cp LICENSE "$SWITCHBOARD_STAGE/LICENSE.txt"
printf 'Drag Switchboard to Applications.\n\nThis build is ad hoc signed and not notarized. After the first open attempt, use System Settings > Privacy & Security > Open Anyway if you trust this download.\n\nInstallation guide: https://switchboard.quasa0.com/#install\nSource: https://github.com/quasa0/switchboard\n' > "$SWITCHBOARD_STAGE/Read me.txt"
hdiutil create -volname Switchboard -srcfolder "$SWITCHBOARD_STAGE" -ov -format UDZO "$SWITCHBOARD_RELEASE/Switchboard-$SWITCHBOARD_VERSION-universal.dmg"
python3 scripts/release-manifest.py "$SWITCHBOARD_RELEASE"
python3 scripts/update-appcast.py "$SWITCHBOARD_RELEASE" "$SWITCHBOARD_SPARKLE_TOOLS"
printf 'Release artifacts: %s\n' "$SWITCHBOARD_RELEASE"
