#!/usr/bin/env bash
# Builds Moire.app into ./build, ad-hoc signed so it runs without a developer certificate.
#
#   VERSION=1.2.0   sets the version shown in Finder and About (default: the one in Resources/Info.plist)
#   UNIVERSAL=1     builds for Apple Silicon and Intel in one app (used for releases)
set -euo pipefail

cd "$(dirname "$0")"

arch_flags=()
if [ "${UNIVERSAL:-0}" = "1" ]; then
    arch_flags=(--arch arm64 --arch x86_64)
fi

swift build -c release --product Moire ${arch_flags[@]+"${arch_flags[@]}"}
binary="$(swift build -c release --product Moire ${arch_flags[@]+"${arch_flags[@]}"} --show-bin-path)/Moire"

app="build/Moire.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/Moire"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

if [ -n "${VERSION:-}" ]; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$app/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$VERSION" "$app/Contents/Info.plist"
fi

codesign --force --sign - "$app"
echo "Built $app"
