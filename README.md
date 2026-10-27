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

[Install](#-install) · [Highlights](#-highlights) · [How it works](#-how-it-works) · [Folders](#-comparing-folders) · [Shortcuts](#%EF%B8%8F-shortcuts) · [Roadmap](#%EF%B8%8F-roadmap) · [Building](#-building)

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
curl -fsSL https://sherin.dev/moire/install.sh | bash
```

Pin a release with `bash -s`:

```bash
curl -fsSL https://sherin.dev/moire/install.sh | bash -s v1.0.0
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

## 🗺️ Roadmap

Moire is growing into a full replacement for tools like Beyond Compare. Speed comes first: Moire has to compare millions of files at once and stay smooth, so every phase below builds on the speed foundation in phase 0.

### ⚡ Phase 0: speed foundation

The base for everything else. Folder comparison in 1.0 reads one file at a time and keeps the whole tree in memory before it shows anything, which is fine for a project folder but not for millions of files.

- [ ] **Read folders on every core.** Walk both trees in parallel with a work-stealing pool (one worker per core), and read file details in batches per folder with `getattrlistbulk` instead of one system call per file.
- [ ] **Choose how files are compared,** per comparison, from cheap to thorough:
  - **Metadata only:** size and modification date, without opening a single file. Made for network disks and slow USB drives. A tolerance for dates handles FAT disks (2 seconds) and daylight saving shifts.
  - **Quick:** size, then a hash of the first and last 64 KB. Catches nearly every change at a fraction of the reads.
  - **Binary:** every byte, so a file only counts as identical when it really is.
  - **Line by line:** text files are compared as text, with the ignore options (spaces, case, line endings), and the folder list shows how many lines changed per file.
- [ ] **A sensible default per disk.** Moire detects when a folder is on a network volume and starts in *Metadata only* there, with one click to compare contents after all.
- [ ] **Cheapest check first.** Every method stops at the first check that settles it: a different size needs no reads at all, and *Binary* only reads whole files once sizes match. Whole files are hashed with a fast hash (xxHash3 or BLAKE3) on all cores, using memory-mapped reads.
- [ ] **I/O tuned to the disk.** Keep a separate limit for reads in flight, so a fast SSD is used fully and a network share or USB disk is not flooded.
- [ ] **Hash cache.** Remember hashes by inode, size and modification date, so comparing the same folders again is close to instant.
- [ ] **Show results while working.** Rows appear as soon as they are known, with live progress (files per second, bytes per second, time left), and a comparison can be stopped at any moment.
- [ ] **Compact memory.** Store the tree as flat arrays with shared path parts instead of one object per file, so ten million entries fit in a few hundred MB.
- [ ] **A list that scales.** Show folder results in an AppKit outline view that only draws visible rows, so scrolling stays smooth with millions of rows.
- [ ] **Huge text files.** Memory-map the files, hash lines on all cores, and draw only the visible lines, so a file with millions of lines opens and scrolls without delay.
- [ ] **Benchmarks in CI.** A fixed set of large test trees and files, measured on every change, so a slowdown is caught before it ships.

### 1. Daily use

- [ ] **Search** in the comparison (⌘F), with next and previous match on both sides, and **Go to Line** (⌘L).
- [ ] **Syntax highlighting** for common languages, worked out only for the visible lines and off the main thread.
- [ ] **Edit in the comparison itself**, with the markings updating as you type, instead of a separate edit mode.
- [ ] **Reload automatically** when a file changes on disk (FSEvents), and ask first when there are unsaved edits.
- [ ] **Folder filters:** include and exclude masks such as `*.swift` or `-node_modules/`, and follow `.gitignore`.

### 2. Merging

- [ ] **Three-way merge** with the common base, left, right and a result pane, so Moire can be used as `git mergetool`.
- [ ] **Pick single lines** from a change, not only the whole block.
- [ ] **Export** a comparison as a unified diff (patch) or as an HTML report.

### 3. Folder sync

- [ ] **Copy, mirror or update** from left to right or back, always with a preview of what will happen first.
- [ ] **Delete (to the Trash), rename and copy** files straight from the folder list.

### 4. Other kinds of files

- [ ] **Hex view** for files that are not text, with the changed bytes marked.
- [ ] **Images** side by side, as an overlay, and as a difference mask.
- [ ] **Tables and CSV**, compared cell by cell, with key columns to match rows.
- [ ] **Archives** such as zip, opened like a folder.
- [ ] **PDF and Word** documents, compared by their text.

### 5. Workflow

- [ ] **Sessions:** saved comparisons with their settings, and a list of recent ones.
- [ ] **Several comparisons at once,** in tabs or windows.
- [ ] **Rules for differences that do not matter:** comments, regular expressions, and line endings, set per file type.
- [ ] **Align lines by hand** when the automatic pairing is wrong.
- [ ] **Remote sources:** SFTP, FTP, S3 and other cloud storage.
- [ ] **Command line and scripting** for automated comparisons and reports, and **printing**.

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
