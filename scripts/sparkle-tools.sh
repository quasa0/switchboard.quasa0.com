#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SWITCHBOARD_TOOLS_DIR="$PWD/.build/sparkle-tools/2.10.0"
SWITCHBOARD_TOOLS_ARCHIVE="$SWITCHBOARD_TOOLS_DIR/Sparkle-2.10.0.tar.xz"
mkdir -p "$SWITCHBOARD_TOOLS_DIR"
if [ ! -f "$SWITCHBOARD_TOOLS_ARCHIVE" ]; then
  curl --fail --location --proto '=https' --tlsv1.2 \
    https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz \
    -o "$SWITCHBOARD_TOOLS_ARCHIVE"
fi
printf 'c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c  %s\n' "$SWITCHBOARD_TOOLS_ARCHIVE" | shasum -a 256 -c - >&2
if [ ! -x "$SWITCHBOARD_TOOLS_DIR/bin/sign_update" ]; then
  tar -xf "$SWITCHBOARD_TOOLS_ARCHIVE" -C "$SWITCHBOARD_TOOLS_DIR"
fi
printf '%s\n' "$SWITCHBOARD_TOOLS_DIR"
