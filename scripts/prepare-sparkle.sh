#!/bin/bash
# Download and verify Sparkle's release tools; print their directory.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/sparkle-version.sh
deps="$PWD/.deps"
archive="$deps/Sparkle-$SPARKLE_VERSION.tar.xz"
destination="$deps/sparkle-$SPARKLE_VERSION"
mkdir -p "$deps"
if [ ! -f "$archive" ]; then
    curl -fL --retry 3 "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" -o "$archive.download" >&2
    mv "$archive.download" "$archive"
fi
printf '%s  %s\n' "$SPARKLE_ARCHIVE_SHA256" "$archive" | shasum -a 256 -c - >&2
if [ ! -d "$destination" ]; then
    staging=$(mktemp -d "$deps/sparkle-prepare.XXXXXX")
    trap 'rm -rf "$staging"' EXIT
    tar -xJf "$archive" -C "$staging"
    mv "$staging" "$destination"
    trap - EXIT
fi
printf '%s\n' "$destination"
