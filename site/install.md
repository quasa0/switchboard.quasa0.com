# Install Switchboard

Switchboard is a native macOS app for saved Claude Code and Codex subscription logins.
Source: https://github.com/quasa0/switchboard
License: MIT
Current release: 0.6.1
Requirements: macOS 14 or newer; Apple silicon (arm64) or Intel (x86_64).

## Agent boundaries

Installation needs no existing account credentials. Do not read or change Keychain items, Claude configuration, Codex auth.json, browser cookies, or saved Switchboard account files. Do not run logout. Do not close someone’s coding sessions. Do not use sudo, disable Gatekeeper, or strip quarantine. The user completes system approvals and official browser sign-in.

Check for an existing app in /Applications/Switchboard.app and ~/Applications/Switchboard.app. If one is running, ask the user to quit it before an update. Keep the existing location and a backup during an update. Never create a duplicate installation or downgrade without the user’s direction. Do not replace a locally development-signed build automatically: changing its signing identity may affect Keychain trust.

## Download and verify

Prefer the universal ZIP for agent installation. The manifest at https://switchboard.quasa0.com/release.json records version, architecture, signing status, URLs, SHA-256 hashes, and file sizes. Verify that it matches the version below before proceeding.

Run these commands in a shell that stops on failure:

```sh
set -eu
[ "$(uname -s)" = Darwin ] || { echo 'Switchboard requires macOS.' >&2; exit 1; }
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || { echo 'macOS 14+ required.' >&2; exit 1; }
case "$(uname -m)" in arm64|x86_64) ;; *) echo 'Unsupported architecture.' >&2; exit 1 ;; esac
SWITCHBOARD_DOWNLOAD=$(mktemp -d "${TMPDIR:-/tmp}/switchboard-install.XXXXXX")
SWITCHBOARD_RELEASE_URL=https://github.com/quasa0/switchboard/releases/download/v0.6.1
curl --fail --location --proto '=https' --tlsv1.2 "$SWITCHBOARD_RELEASE_URL/Switchboard-0.6.1-universal.zip" -o "$SWITCHBOARD_DOWNLOAD/Switchboard-0.6.1-universal.zip"
curl --fail --location --proto '=https' --tlsv1.2 "$SWITCHBOARD_RELEASE_URL/SHA256SUMS.txt" -o "$SWITCHBOARD_DOWNLOAD/SHA256SUMS.txt"
(cd "$SWITCHBOARD_DOWNLOAD" && awk '$2 == "Switchboard-0.6.1-universal.zip" { print }' SHA256SUMS.txt > ZIP.sha256 && test "$(wc -l < ZIP.sha256 | tr -d ' ')" = 1 && shasum -a 256 -c ZIP.sha256)
ditto -x -k "$SWITCHBOARD_DOWNLOAD/Switchboard-0.6.1-universal.zip" "$SWITCHBOARD_DOWNLOAD/unpacked"
codesign --verify --deep --strict "$SWITCHBOARD_DOWNLOAD/unpacked/Switchboard.app"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$SWITCHBOARD_DOWNLOAD/unpacked/Switchboard.app/Contents/Info.plist")" = com.quasa0.switchboard
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SWITCHBOARD_DOWNLOAD/unpacked/Switchboard.app/Contents/Info.plist")" = 0.6.1
```

Stop on a failed download, checksum mismatch, unexpected bundle identifier, or invalid signature. Checksums are served by the same publisher; they are integrity checks, not independent publisher authentication.

For a **new installation only**, after confirming neither Applications folder contains Switchboard:

```sh
mkdir -p "$HOME/Applications"
test ! -e /Applications/Switchboard.app
test ! -e "$HOME/Applications/Switchboard.app"
ditto "$SWITCHBOARD_DOWNLOAD/unpacked/Switchboard.app" "$HOME/Applications/Switchboard.app"
codesign --verify --deep --strict "$HOME/Applications/Switchboard.app"
```

For an update, preserve the existing app as a backup, copy into the same location, and verify the installed signature before removing the backup. Do not touch ~/Library/Application Support/Switchboard or any Keychain entry. Clean up only the temporary directory you created after verification. Do not automatically launch the app during installation; let the user open it when ready.

## First open

This release is ad hoc signed and **not notarized**. Apple may block its first launch. After attempting to open it, the user can choose System Settings → Privacy & Security → Open Anyway if they trust the download. Do not bypass this decision with a shell command.
Apple’s guide: https://support.apple.com/en-us/102445

## Account setup

1. Confirm the official CLI is installed for each provider the user wants. Do not install extra tools without direction. Claude Code: https://code.claude.com/docs/en/setup. Codex: https://github.com/openai/codex#quickstart.
2. The user opens Switchboard and chooses Add account → Save current login, or signs in through the app.
3. Save each account before adding the next. Do not run Claude logout between accounts; it can revoke saved refresh tokens.
4. Before switching, the user closes that provider’s running sessions. Select an account in Switchboard and start a new CLI session.

Codex must use file-based credential storage. Keyring, auto, and ephemeral storage are not supported. Claude requires its macOS Keychain login. The app does not switch browser or ChatGPT desktop sessions.

## Build from source instead

Requires Swift 5.10+ through Xcode Command Line Tools. Sparkle 2.10.0 is pinned for native signed updates.

```sh
git clone https://github.com/quasa0/switchboard.git
cd switchboard
git checkout --detach v0.6.1
swift test
./scripts/install.sh
```

The source installer places the app in ~/Applications and refuses to install while Switchboard is running. It uses an available Apple Development identity or ad hoc signing. Set SWITCHBOARD_SIGNING_IDENTITY=- explicitly for ad hoc signing. Follow the same existing-installation checks above.

## Verify and report

Report the installed path, bundle version, architecture, checksum result, and signing limitation. Installation verification must not read credentials. If a UI test is needed, use `Switchboard.app/Contents/MacOS/Switchboard --demo`; quit that preview when finished.
