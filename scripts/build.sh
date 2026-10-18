#!/bin/bash
# Builds macha and wraps it in a minimal macha.app.
#
# macOS only shows the Location Services prompt (and remembers the answer) for a process that
# lives in an app bundle with an Info.plist and a code signature; a bare command-line binary
# never gets one. The binary is still run as a command: macha.app/Contents/MacOS/macha.
#
# usage: scripts/build.sh [output directory (default: .build)]
#        CONFIG=debug scripts/build.sh      # debug build instead of release
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
config="${CONFIG:-release}"
app="${1:-$here/.build}/macha.app"

cd "$here"
# --disable-sandbox: SwiftPM's own sandbox can't nest inside Homebrew's.
swift build --disable-sandbox -c "$config"
binary="$(swift build --disable-sandbox -c "$config" --show-bin-path)/macha"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/macha"
cp Resources/Info.plist "$app/Contents/Info.plist"

# Ad-hoc signature (no developer account needed). By default an ad-hoc signature is identified by
# the hash of the exact binary, so every rebuild would look like a new app to macOS and lose its
# privacy permissions (Location, Bluetooth). The explicit requirement below identifies it by name instead.
id=com.github.humanfriend22.macha
codesign --force --sign - --identifier "$id" -r="designated => identifier \"$id\"" "$app"
echo "Built $app"
echo "Run it with: $app/Contents/MacOS/macha"
