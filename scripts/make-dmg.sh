#!/usr/bin/env bash
# Builds build/Moire-<version>.dmg from build/Moire.app: the app, an Applications link and the
# drag-to-install background. The version is the built app's own, and the disk is named
# "Moire <version>". Run ./build-app.sh first (VERSION=1.2.0 ./build-app.sh sets the version).
#
# Uses dmgbuild, which writes the window layout itself, so it works without a Finder session
# (in CI too). It is installed into build/dmgbuild-venv on first use.
set -euo pipefail

cd "$(dirname "$0")/.."

dmgbuild_version="1.6.7"
app="build/Moire.app"
[ -d "$app" ] || { echo "make-dmg: $app is missing; run ./build-app.sh first" >&2; exit 1; }
version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
[ -n "$version" ] || { echo "make-dmg: $app has no CFBundleShortVersionString" >&2; exit 1; }
dmg="build/Moire-$version.dmg"

venv="build/dmgbuild-venv"
if [ ! -x "$venv/bin/dmgbuild" ]; then
    python3 -m venv "$venv"
    "$venv/bin/pip" install --quiet "dmgbuild==$dmgbuild_version"
fi

volume_name="Moire $version"
# Only the DMG of this build stays, so the release picks up exactly one.
rm -f build/Moire.dmg build/Moire-*.dmg
"$venv/bin/dmgbuild" -s scripts/dmg-settings.py -D app="$app" "$volume_name" "$dmg"
echo "Built $dmg"
