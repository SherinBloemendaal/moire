<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/banner-dark.svg">
  <img alt="Moire: see what changed, beautifully" src="assets/banner-light.svg" width="100%">
</picture>

<br>

<a href="https://github.com/SherinBloemendaal/moire/actions/workflows/ci.yml"><img src="https://github.com/SherinBloemendaal/moire/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
<a href="https://github.com/SherinBloemendaal/moire/releases/latest"><img src="https://img.shields.io/github/v/release/SherinBloemendaal/moire?style=flat-square&color=7C5CFF" alt="Latest release"></a>
<a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-yellow.svg?style=flat-square" alt="License: MIT"></a>
<img src="https://img.shields.io/badge/swift-6.2%2B-F05138.svg?style=flat-square" alt="Swift 6.2+">
<img src="https://img.shields.io/badge/platform-macOS%2015%2B-555555.svg?style=flat-square" alt="macOS 15+">

**Moire** is a native macOS app for comparing text, files and folders side by side.<br>
Repo: [github.com/SherinBloemendaal/moire](https://github.com/SherinBloemendaal/moire)

[Install](#-install) · [Highlights](#-highlights) · [How it works](#-how-it-works) · [Folders](#-comparing-folders) · [Shortcuts](#%EF%B8%8F-shortcuts) · [Building](#-building)

</div>

<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/preview-dark.svg">
  <img alt="Moire comparing two versions of a Swift file side by side, with the changed words marked" src="assets/preview-light.svg" width="100%">
</picture>

> *A moiré is the shimmering pattern you see when two almost identical grids lie on top of each other. It only shows up where they differ, and showing that is all Moire does.*

## ✨ Highlights

- **Side by side or unified.** Lines are aligned across both sides, changed lines sit next to their new version, and the exact words that changed are marked.
- **Copy changes across.** Hover a change and click → or ← to take that version, or use ⌥⌘→ and ⌥⌘← on the current change. Save writes the file back in its own encoding and line endings.
- **Jump between changes** with ⌥⌘↓ and ⌥⌘↑, or click a mark in the change map next to the scroll bar to see where every change sits in the whole file.
- **Only changes.** Fold away long runs of unchanged lines and keep three lines of context around each change. Click a fold to open it.
- **Paste or type.** No files needed: paste two snippets, or edit either side, and the comparison updates as you type.
- **Compare folders.** Every file in both folders is compared by its contents. Double-click a file to see what changed in it.
- **Ignore what does not matter:** spaces at the line ends, all spaces, or upper and lower case.
- **Reads what you have:** UTF-8, UTF-16 and Latin-1, with or without a byte order mark, and LF, CRLF or CR line endings. Files that are not text are compared byte for byte.
- **Fast on big files.** Moire uses Myers' algorithm in linear space, the same idea behind `git diff`, and does the work off the main thread.
- **Light and dark**, following your Mac.

## 📦 Install

```bash
curl -fsSL https://raw.githubusercontent.com/SherinBloemendaal/moire/main/install.sh | bash
```

Pin a release with `bash -s`:

```bash
curl -fsSL https://raw.githubusercontent.com/SherinBloemendaal/moire/main/install.sh | bash -s v1.0.0
```

The script downloads `Moire.zip` from the GitHub release, checks it against `SHA256SUMS`, and installs `Moire.app` into `/Applications` (or `~/Applications` when `/Applications` is not writable; override with `MOIRE_INSTALL`). Run it again to upgrade in place. To uninstall, move `Moire.app` to the Trash.

### Download

Download [`Moire.dmg`](https://github.com/SherinBloemendaal/moire/releases/latest/download/Moire.dmg), open it, and drag Moire onto the Applications folder. It runs on Apple Silicon and Intel Macs with macOS 15 or later.

<details>
<summary><b>Other downloads and the first launch</b></summary>

<br>

Every [release](https://github.com/SherinBloemendaal/moire/releases/latest) also has `Moire.zip` (the app on its own) and `SHA256SUMS`, which covers both downloads.

> [!NOTE]
> Moire is not notarized by Apple, so macOS blocks it the first time when it was downloaded with a browser. Open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. Or clear the download flag:
>
> ```bash
> xattr -dr com.apple.quarantine /Applications/Moire.app
> ```
>
> The install script does not need this: files downloaded with `curl` are not flagged.

</details>

## 🧭 How it works

1. **Lines.** Both sides are split into lines. With an ignore option on, each line is first reduced to what counts (for example without spaces), so `foo( x )` and `foo(x)` can match.
2. **Matching.** Lines that only one side has are set aside first: they can never match, and leaving them out keeps a full rewrite fast. Myers' algorithm then finds the smallest set of lines to remove and add.
3. **Pairing.** Inside each change, removed and added lines are paired in order. A pair is shown on one row, and the words in it are compared again to mark exactly what changed.
4. **Merging.** Copying a change replaces those lines on the other side. Moire compares again right away, so the next change is ready to go.

## 📁 Comparing folders

Switch to **Folders** in the toolbar (or press ⇧⌘O) and choose or drop two folders.

- Files are compared by size first, then byte by byte. A file that was only saved again, with a new date but the same contents, counts as identical.
- A folder is marked *Different* when anything inside it differs. Click its arrow to fold it.
- **Differences** hides everything that is the same. **Hidden Files** includes names that start with a dot, such as `.git` and `.env`.
- Symbolic links are compared by where they point and are never followed.
- Double-click a file to open it in the text comparison; **Folders** in the toolbar takes you back.

## ⌨️ Shortcuts

| Action                            | Shortcut |
| --------------------------------- | -------- |
| Open one or two files             | ⌘O       |
| Compare folders                   | ⇧⌘O      |
| Save changed sides                | ⌘S       |
| Reload the files from disk        | ⌘R       |
| Next / previous change            | ⌥⌘↓ / ⌥⌘↑ |
| Copy the change to the right/left | ⌥⌘→ / ⌥⌘← |
| Edit text / show differences      | ⌘E       |
| Swap the sides                    | ⇧⌘X      |
| Side by side / unified            | ⌃⌘1 / ⌃⌘2 |
| Only show changes                 | ⌥⌘F      |
| Bigger / smaller / actual text    | ⌘+ / ⌘− / ⌘0 |

### From the terminal

Run the app's binary with two files or two folders. Paths are read relative to the folder you are in:

```bash
/Applications/Moire.app/Contents/MacOS/Moire old.txt new.txt
```

To use Moire as a Git difftool:

```bash
git config --global difftool.moire.cmd '/Applications/Moire.app/Contents/MacOS/Moire "$LOCAL" "$REMOTE"'
git difftool --tool=moire
```

## 🔨 Building

Requires macOS 15 or later and Xcode 26 (Swift 6.2 or later). There are no dependencies.

```bash
./build-app.sh               # build/Moire.app for this Mac
UNIVERSAL=1 ./build-app.sh   # Apple Silicon and Intel in one app
scripts/make-dmg.sh          # build/Moire.dmg from build/Moire.app
swift test                   # run the tests
```

Releases are built by GitHub Actions: push a tag like `v1.2.0` and the [Release workflow](.github/workflows/release.yml) tests, builds a universal `Moire.app`, and publishes `Moire.dmg` and `Moire.zip` with `SHA256SUMS`.

<details>
<summary><b>Project layout</b></summary>

<br>

| Path                    | What it holds                                                                 |
| ----------------------- | ----------------------------------------------------------------------------- |
| `Sources/MoireKit`      | The diff engine: Myers, line and word comparison, merging, folders. No AppKit. |
| `Sources/Moire`         | The SwiftUI app: text and folder comparison, change map, editing.             |
| `Tests/MoireKitTests`   | Tests for the engine, including checks against a brute-force reference.       |
| `install.sh`            | The install script.                                                           |
| `art/`                  | The app icon and the DMG background, as SVG.                                  |
| `assets/`               | The banner and the preview in this README, light and dark.                    |
| `scripts/make-art.sh`   | Turns `art/` into `Resources/AppIcon.icns` and the DMG background.            |
| `scripts/make-dmg.sh`   | Builds `Moire.dmg` with [dmgbuild](https://github.com/dmgbuild/dmgbuild).     |

</details>

## 📄 License

MIT. See [LICENSE](LICENSE).
