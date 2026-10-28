#!/usr/bin/env bash
# Opens build/Moire.app the ways macOS can (from a terminal with files, with `open -a`, a second
# set while it runs, a plain launch, files into an empty window) and counts its windows, starting
# without saved window state each time. Build first with ./build-app.sh.
set -euo pipefail

cd "$(dirname "$0")/.."
app="$PWD/build/Moire.app"
work="$(mktemp -d)"
trap 'pkill -x Moire 2>/dev/null || true; rm -rf "$work"' EXIT

cat > "$work/count.swift" <<'SWIFT'
import CoreGraphics
let windows = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
print(windows.filter {
    ($0[kCGWindowOwnerName as String] as? String) == "Moire" && ($0[kCGWindowLayer as String] as? Int) == 0
        && ((($0[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double) ?? 0) > 300
}.count)
SWIFT
swiftc -O "$work/count.swift" -o "$work/count" 2>/dev/null

reset() { rm -rf "$HOME/Library/Saved Application State/io.github.sherinbloemendaal.moire.savedState"; }
quit() { pkill -x Moire 2>/dev/null || true; sleep 1; reset; }
echo one > "$work/l.txt"
echo two > "$work/r.txt"
failed=0
check() {
    local got
    got="$("$work/count")"
    if [ "$got" = "$2" ]; then echo "ok    $1: $got window(s)"; else echo "FAIL  $1: $got window(s), expected $2"; failed=1; fi
}

reset
"$app/Contents/MacOS/Moire" "$work/l.txt" "$work/r.txt" >/dev/null 2>&1 &
sleep 4; check "launched with files" 1; quit
open -a "$app" "$work/l.txt" "$work/r.txt"; sleep 4; check "open -a with files" 1
open -a "$app" "$work/r.txt" "$work/l.txt"; sleep 3; check "a second pair while running" 2; quit
"$app/Contents/MacOS/Moire" >/dev/null 2>&1 &
sleep 4; check "plain launch" 1
open -a "$app" "$work/r.txt" "$work/l.txt"; sleep 3; check "files into the empty window" 1; quit
exit "$failed"
