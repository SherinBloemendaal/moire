#!/usr/bin/env bash
# Install Moire from GitHub releases.
# https://github.com/SherinBloemendaal/moire
#
#   curl -fsSL https://raw.githubusercontent.com/SherinBloemendaal/moire/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/SherinBloemendaal/moire/main/install.sh | bash -s v1.0.0
#
# MOIRE_VERSION pins a release tag, MOIRE_INSTALL picks the folder (default /Applications,
# or ~/Applications when /Applications is not writable).

if [ -z "${BASH_VERSION:-}" ]; then
    echo "moire: run this script with bash" >&2
    exit 1
fi

set -euo pipefail

repo="SherinBloemendaal/moire"
version="${1:-${MOIRE_VERSION:-latest}}"

fail() {
    echo "moire: $*" >&2
    exit 1
}

[ "$(uname -s)" = "Darwin" ] || fail "Moire is a macOS app."

macos_major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$macos_major" -ge 15 ] || fail "Moire needs macOS 15 or later (this Mac runs $(sw_vers -productVersion))."

if pgrep -xq Moire; then
    fail "Moire is running. Quit it first, then run this script again."
fi

if [ "$version" = "latest" ]; then
    base="https://github.com/$repo/releases/latest/download"
else
    base="https://github.com/$repo/releases/download/$version"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading Moire ($version)…"
curl -fsSL "$base/Moire.zip" -o "$tmp/Moire.zip" || fail "could not download $base/Moire.zip"
curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS" || fail "could not download $base/SHA256SUMS"

expected="$(awk '$2 == "Moire.zip" { print $1 }' "$tmp/SHA256SUMS")"
actual="$(shasum -a 256 "$tmp/Moire.zip" | awk '{ print $1 }')"
[ -n "$expected" ] || fail "SHA256SUMS has no entry for Moire.zip"
[ "$expected" = "$actual" ] || fail "checksum mismatch for Moire.zip (expected $expected, got $actual)"

ditto -x -k "$tmp/Moire.zip" "$tmp/unpacked"
[ -d "$tmp/unpacked/Moire.app" ] || fail "the download does not contain Moire.app"

destination="${MOIRE_INSTALL:-/Applications}"
if [ -z "${MOIRE_INSTALL:-}" ] && [ ! -w "$destination" ]; then
    destination="$HOME/Applications"
fi
mkdir -p "$destination"

rm -rf "$destination/Moire.app"
ditto "$tmp/unpacked/Moire.app" "$destination/Moire.app"
# The app is not notarized. Downloads made by curl are not quarantined, but clear the flag in case.
xattr -dr com.apple.quarantine "$destination/Moire.app" 2>/dev/null || true

installed="$(defaults read "$destination/Moire.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "$version")"
echo "Installed Moire $installed to $destination/Moire.app"
echo "Open it with: open \"$destination/Moire.app\""
