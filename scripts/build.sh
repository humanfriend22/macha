#!/bin/bash
# Builds macha and wraps it in a minimal macha.app.

# usage (from the repo root): scripts/build.sh [compile|package|all] [output directory (default: .build)]
#        With no arguments, does both (all). The Homebrew formula runs them as two
#        steps so it can print a status message between them.
#        CHANNEL=debug scripts/build.sh      # debug build instead of release
set -euo pipefail

step="${1:-}"
channel="${CHANNEL:-release}"
app="${2:-.build}/macha.app"

if [ "$step" != compile ] && [ "$step" != package ] && [ "$step" != all ]; then
  echo "usage: scripts/build.sh [compile|package|all] [output directory]"
  exit 1
fi

# Compile the Swift binary
if [ "$step" = compile ] || [ "$step" = all ]; then
  swift build --disable-sandbox -c "$channel"
fi

# Package the binary into an ad-hoc signed app
if [ "$step" = package ] || [ "$step" = all ]; then
  binary="$(swift build --disable-sandbox -c "$channel" --show-bin-path)/macha"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  cp "$binary" "$app/Contents/MacOS/macha"
  cp Resources/Info.plist "$app/Contents/Info.plist"

  # By default an ad-hoc signature is identified by the hash of the exact binary,
  # so every rebuild would look like a new app to macOS.
  # The explicit requirement below identifies it by name instead.
  id=com.github.humanfriend22.macha
  codesign --force --sign - --identifier "$id" -r="designated => identifier \"$id\"" "$app"
  echo "Packaged $app"
fi
