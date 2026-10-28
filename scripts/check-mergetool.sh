#!/usr/bin/env bash
# Runs build/Moire.app as git mergetool on a real conflict, quits it without saving through an
# Apple Event, and checks that git keeps the file unmerged. Build first with ./build-app.sh.
set -euo pipefail

app="$(cd "$(dirname "$0")/.." && pwd)/build/Moire.app"
repo="$(mktemp -d)"
trap 'pkill -x Moire 2>/dev/null || true; rm -rf "$repo"' EXIT
cd "$repo"
git init -q -b main
git config user.email test@example.com
git config user.name test
printf 'a\nb\nc\n' > f.txt && git add f.txt && git commit -qm base
git checkout -qb side && printf 'a\nSIDE\nc\n' > f.txt && git commit -qam side
git checkout -q main && printf 'a\nMAIN\nc\n' > f.txt && git commit -qam main
git merge -q side >/dev/null 2>&1 || true
git config merge.tool moire
git config mergetool.moire.cmd "\"$app/Contents/MacOS/Moire\" --merge \"\$BASE\" \"\$LOCAL\" \"\$REMOTE\" \"\$MERGED\""
git config mergetool.moire.trustExitCode true
git config mergetool.keepBackup false

rm -rf "$HOME/Library/Saved Application State/io.github.sherinbloemendaal.moire.savedState"
git mergetool --no-prompt f.txt >/dev/null 2>&1 &
tool=$!
sleep 5
osascript -e 'tell application id "io.github.sherinbloemendaal.moire" to quit'
status=0
wait "$tool" || status=$?
unmerged="$(git diff --name-only --diff-filter=U)"
if [ "$status" -ne 0 ] && [ "$unmerged" = "f.txt" ]; then
    echo "ok    quitting without saving leaves f.txt unmerged (git mergetool exit $status)"
else
    echo "FAIL  git mergetool exit $status, unmerged: '$unmerged'"
    exit 1
fi
