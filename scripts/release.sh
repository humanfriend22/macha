#!/bin/bash

set -euo pipefail

version="${1:-}"

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: scripts/release.sh <version>" >&2
  exit 1
fi

# The version shown by `macha --version`
sed -i '' -E "s/version: \"[0-9.]+\"/version: \"$version\"/" Sources/macha/Macha.swift
# The version inside macha.app
sed -i '' -E "s|(<key>CFBundleVersion</key><string>)[0-9.]+(</string>)|\1$version\2|" Resources/Info.plist

# Make sure both edits actually happened
grep -q "version: \"$version\"" Sources/macha/Macha.swift
grep -q "<string>$version</string>" Resources/Info.plist

echo "Version set to $version in Sources/macha/Macha.swift and Resources/Info.plist."
echo
echo "Next, publish it:"
echo "  git add -A && git commit -m \"v$version\""
echo "  git push"
echo "  git tag v$version && git push --tags"
echo "  curl -sL https://github.com/humanfriend22/macha/archive/refs/tags/v$version.tar.gz | shasum -a 256"
echo
echo "Then in the tap repo: put v$version and that sha256 in the url and sha256 lines of"
echo "Formula/macha.rb, commit, push, and run: brew upgrade macha"
