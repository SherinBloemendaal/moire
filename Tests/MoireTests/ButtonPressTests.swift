import AppKit
import Foundation
@testable import Moire
import MoireKit
import SwiftUI
import Testing

/// Presses the real buttons of real views, through the accessibility elements SwiftUI gives
/// them: the same way VoiceOver presses a button, inside this process.
@MainActor
enum Press {
    static func host(_ view: some View, size: NSSize) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        // What an assistive app asks for; without it SwiftUI builds no accessibility elements.
        NSApp.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.contentView = host
        window.orderFrontRegardless()
        return (window, host)
    }

    /// An accessibility attribute, asked through the method itself: SwiftUI's nodes answer the
    /// methods but not key-value coding.
    private static func value(_ element: NSObject, _ selector: Selector) -> Any? {
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue()
    }

    static func elements(in root: NSObject) -> [NSObject] {
        var found: [NSObject] = []
        var queue: [NSObject] = [root]
        while let element = queue.popLast() {
            found.append(element)
            let children = value(element, #selector(NSAccessibilityProtocol.accessibilityChildren)) as? [Any] ?? []
            queue += children.compactMap { $0 as? NSObject }
        }
        return found
    }

    static func button(_ title: String, in root: NSView) -> NSObject? {
        elements(in: root).first { element in
            guard (value(element, #selector(NSAccessibilityProtocol.accessibilityRole)) as? String) == NSAccessibility.Role.button.rawValue else { return false }
            let label = value(element, #selector(NSAccessibilityProtocol.accessibilityLabel)) as? String
            let title2 = value(element, #selector(NSAccessibilityProtocol.accessibilityTitle)) as? String
            return label == title || title2 == title
        }
    }

    static func press(_ title: String, in root: NSView) -> Bool {
        guard let button = button(title, in: root), button.responds(to: #selector(NSAccessibilityProtocol.accessibilityPerformPress)) else { return false }
        _ = button.perform(#selector(NSAccessibilityProtocol.accessibilityPerformPress))
        return true
    }

    /// Presses until `done` holds: a button stays disabled until its view is ready (the sync plan
    /// is worked out after the sheet appears), and pressing a disabled button does nothing.
    static func press(_ title: String, in root: NSView, until done: () -> Bool) async throws -> Bool {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            _ = press(title, in: root)
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(5))
                if done() { return true }
            }
        }
        return false
    }

    static func wait(_ seconds: Double = 5, until ready: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
@Suite(.serialized)
struct SyncSheetButtonTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func folder(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "moire-press-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path(percentEncoded: false))
        }
        return root
    }

    private func count(_ root: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)).count) ?? 0
    }

    private func model(_ left: URL, _ right: URL) async throws -> FolderModel {
        let model = FolderModel()
        model.pick(.binary)
        model.left = left
        model.right = right
        try await Press.wait { model.isComplete }
        try #require(model.isComplete)
        return model
    }

    @Test func `pressing Sync copies the planned files`() async throws {
        let left = try folder(["a.txt": "a", "deep/b.txt": "b"])
        let right = try folder([:])
        let model = try await model(left, right)
        let (window, host) = Press.host(SyncSheet(model: model, items: []), size: NSSize(width: 560, height: 520))
        defer { window.orderOut(nil) }
        try await Press.wait { Press.button("Sync", in: host) != nil }

        #expect(try await Press.press("Sync", in: host) { Press.button("Stop", in: host) != nil || Press.button("Close", in: host) != nil })
        try await Press.wait { FileManager.default.fileExists(atPath: right.appending(path: "deep/b.txt").path(percentEncoded: false)) }
        #expect(try String(contentsOf: right.appending(path: "a.txt"), encoding: .utf8) == "a")
        #expect(try String(contentsOf: right.appending(path: "deep/b.txt"), encoding: .utf8) == "b")
        // The sheet now offers Close instead of Sync.
        try await Press.wait { Press.button("Close", in: host) != nil }
        #expect(Press.button("Close", in: host) != nil)
    }

    @Test func `pressing Cancel before syncing changes nothing`() async throws {
        let left = try folder(["a.txt": "a"])
        let right = try folder([:])
        let model = try await model(left, right)
        let (window, host) = Press.host(SyncSheet(model: model, items: []), size: NSSize(width: 560, height: 520))
        defer { window.orderOut(nil) }
        try await Press.wait { Press.button("Cancel", in: host) != nil }
        #expect(Press.press("Cancel", in: host))
        try await Task.sleep(for: .milliseconds(300))
        #expect(count(right) == 0)
    }

    @Test func `pressing Stop during a sync leaves the rest undone`() async throws {
        var files: [String: String] = [:]
        // Many small files: every copy has a fixed cost, so the sync still runs when Stop is
        // pressed, also on a fast disk (a few big files were done before Stop could be pressed).
        for index in 0..<4000 { files["d\(index % 40)/f\(index).txt"] = "\(index)" }
        let left = try folder(files)
        let right = try folder([:])
        let model = try await model(left, right)
        let (window, host) = Press.host(SyncSheet(model: model, items: []), size: NSSize(width: 560, height: 520))
        defer { window.orderOut(nil) }
        try await Press.wait { Press.button("Sync", in: host) != nil }

        #expect(try await Press.press("Sync", in: host) { Press.button("Stop", in: host) != nil })
        #expect(Press.press("Stop", in: host))
        try await Press.wait(10) { Press.button("Close", in: host) != nil }
        var copied = 0
        for folder in (try? FileManager.default.contentsOfDirectory(atPath: right.path(percentEncoded: false))) ?? [] {
            copied += count(right.appending(path: folder))
        }
        #expect(copied < 4000, "copied \(copied) of 4000")
    }
}

@MainActor
@Suite(.serialized)
struct MergeButtonTests {
    @Test func `pressing Take Left and Save Result writes the merge and tells git it is done`() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "moire-press-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func file(_ name: String, _ text: String) throws -> URL {
            let url = folder.appending(path: name)
            try Data(text.utf8).write(to: url)
            return url
        }
        let output = try file("merged.txt", "<<<<<<< from git\n")
        let model = MergeModel()
        model.openMergetool(base: try file("base.txt", "a\nb\nc\n"), left: try file("left.txt", "a\nLEFT\nc\n"), right: try file("right.txt", "a\nRIGHT\nc\nd\n"), output: output)
        try await Press.wait { model.merge != nil }
        let (window, host) = Press.host(MergeView(model: model), size: NSSize(width: 1240, height: 780))
        defer { window.orderOut(nil) }
        try await Press.wait { Press.button("Take Left", in: host) != nil }

        #expect(model.exitStatus != 0)
        #expect(try await Press.press("Take Left", in: host) { (model.merge?.unresolvedConflicts(model.resolutions).isEmpty) == true })
        #expect(try await Press.press("Save Result", in: host) { !model.isDirty && model.exitStatus == 0 })
        #expect(try String(contentsOf: output, encoding: .utf8) == "a\nLEFT\nc\nd\n")
        #expect(model.exitStatus == 0)
    }
}
