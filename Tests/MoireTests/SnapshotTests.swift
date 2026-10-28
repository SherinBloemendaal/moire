import AppKit
import Foundation
@testable import Moire
import SwiftUI
import Testing

/// Renders real screens of the app to PNG files, to look at them without a screen recording.
/// Only runs when `MOIRE_SNAPSHOTS` names a folder: `MOIRE_SNAPSHOTS=/tmp/shots swift test --filter Snapshot`.
@MainActor
struct SnapshotTests {
    private let folder = ProcessInfo.processInfo.environment["MOIRE_SNAPSHOTS"].map { URL(filePath: $0) }

    private func files(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "moire-shot-\(UUID().uuidString)")
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return root
    }

    /// Lets loading tasks run and SwiftUI and AppKit lay out and draw, until `ready` holds or the
    /// time is up. Sleeping, not spinning the run loop, so work queued on the main actor runs.
    private func settle(_ seconds: Double = 8, until ready: () -> Bool = { false }) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try await Task.sleep(for: .milliseconds(50))
            if ready() {
                try await Task.sleep(for: .milliseconds(800))
                return
            }
        }
        Issue.record("not ready after \(seconds) s")
    }

    private func render(_ view: some View, size: NSSize = NSSize(width: 1240, height: 780), dark: Bool = false, name: String, until ready: () -> Bool = { true }) async throws {
        guard let folder else { return }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.contentView = host
        window.orderFrontRegardless()
        try await settle(until: ready)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            Issue.record("no bitmap for \(name)")
            return
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name).png"))
        window.orderOut(nil)
    }

    @Test func `text comparison`() async throws {
        let root = try files([
            "old/Invoice.swift": "import Foundation\n\nstruct Invoice {\n    let number: String\n    let customer: String // who pays\n    var lines: [Line]\n\n    var total: Decimal {\n        lines.reduce(0) { $0 + $1.price }\n    }\n}\n",
            "new/Invoice.swift": "import Foundation\n\nstruct Invoice: Identifiable {\n    let id: UUID\n    let number: String\n    let customer: Customer // who pays\n    var lines: [Line]\n\n    var total: Decimal {\n        lines.reduce(0) { $0 + $1.unitPrice * $1.quantity }\n    }\n}\n",
        ])
        let state = AppState()
        state.compare.openPair(left: root.appending(path: "old/Invoice.swift"), right: root.appending(path: "new/Invoice.swift"))
        try await render(ContentView(state: state), name: "1-text-light") { state.compare.display != nil }
        try await render(ContentView(state: state), dark: true, name: "2-text-dark") { state.compare.display != nil }
    }

    @Test func `empty start screen`() async throws {
        try await render(ContentView(state: AppState()), dark: true, name: "0-empty-dark")
    }

    @Test func `folder comparison and sync sheet`() async throws {
        let root = try files([
            "a/src/main.swift": "print(1)\n", "a/src/util.swift": "same\n", "a/README.md": "old readme\n", "a/only-left.txt": "l\n",
            "b/src/main.swift": "print(2)\n", "b/src/util.swift": "same\n", "b/README.md": "new readme\n", "b/only-right.txt": "r\n",
        ])
        let state = AppState()
        state.mode = .folders
        state.folders.left = root.appending(path: "a")
        state.folders.right = root.appending(path: "b")
        try await render(ContentView(state: state), name: "3-folders") { !state.folders.isComparing && state.folders.tree != nil }
        try await render(SyncSheet(model: state.folders, items: []), size: NSSize(width: 560, height: 520), name: "4-sync-sheet") { !state.folders.isComparing }
    }

    @Test func `three-way merge`() async throws {
        let root = try files(["base.txt": "one\ntwo\nthree\nfour\n", "left.txt": "one\nTWO\nthree\nfour\n", "right.txt": "one\n2\nthree\nfour and more\n"])
        let state = AppState()
        state.mode = .merge
        state.merge.openMergetool(base: root.appending(path: "base.txt"), left: root.appending(path: "left.txt"), right: root.appending(path: "right.txt"), output: root.appending(path: "out.txt"))
        try await render(ContentView(state: state), name: "5-merge") { state.merge.merge != nil }
    }

    @Test func `hex view of binary files`() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "moire-shot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 4096)
        for index in bytes.indices { bytes[index] = UInt8(index % 251) }
        try Data(bytes).write(to: root.appending(path: "a.bin"))
        bytes[100] = 0xFF
        bytes[2000] = 0xEE
        try Data(bytes).write(to: root.appending(path: "b.bin"))
        let state = AppState()
        state.compare.openPair(left: root.appending(path: "a.bin"), right: root.appending(path: "b.bin"))
        try await render(ContentView(state: state), name: "6-hex") { state.compare.hasBinarySide }
    }
}
