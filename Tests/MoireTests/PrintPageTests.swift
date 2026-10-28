import Foundation
@testable import Moire
import MoireKit
import Testing

/// What Print lays out, built the way the menu item builds it; only the print panel itself is left out.
@MainActor
struct PrintPageTests {
    private func folder(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "moire-print-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return root
    }

    @Test func `has nothing to print before anything is open`() {
        let state = AppState()
        for mode in AppState.Mode.allCases {
            state.mode = mode
            #expect(state.printPage() == nil, "\(mode)")
        }
    }

    @Test func `a text comparison prints both sides and marks the changes`() async throws {
        let root = try folder(["before.txt": "kept\nold & <tagged>\nremoved line\n", "after.txt": "kept\nnew & <tagged>\nadded line\n"])
        let state = AppState()
        state.compare.openPair(left: root.appending(path: "before.txt"), right: root.appending(path: "after.txt"))
        for _ in 0..<400 where state.printPage() == nil { try await Task.sleep(for: .milliseconds(10)) }
        let page = try #require(state.printPage())

        #expect(page.title == "before.txt and after.txt")
        #expect(page.html.contains("before.txt"))
        #expect(page.html.contains("after.txt"))
        #expect(page.html.contains("<tr class=\"same\">"))
        #expect(page.html.contains("<tr class=\"chg\">"))
        #expect(page.html.contains("kept"))
        #expect(page.html.contains("<del>old</del> &amp; &lt;tagged&gt;"))
        #expect(page.html.contains("<ins>new</ins> &amp; &lt;tagged&gt;"))
        #expect(page.html.contains("<del>removed</del> line"))
        #expect(page.html.contains("<ins>added</ins> line"))
    }

    @Test func `a folder comparison prints each difference`() async throws {
        let left = try folder(["same.txt": "s", "changed.txt": "left", "only-left.txt": "l"])
        let right = try folder(["same.txt": "s", "changed.txt": "right", "only-right.txt": "r"])
        let state = AppState()
        state.mode = .folders
        state.folders.pick(.binary)
        state.folders.left = left
        state.folders.right = right
        for _ in 0..<400 where !state.folders.isComplete { try await Task.sleep(for: .milliseconds(10)) }
        let page = try #require(state.printPage())

        #expect(page.title == "Folder comparison")
        #expect(page.html.contains("<tr class=\"diff\"><td style=\"padding-left:10px\">📄 changed.txt</td>"))
        #expect(page.html.contains("<tr class=\"left\"><td style=\"padding-left:10px\">📄 only-left.txt</td>"))
        #expect(page.html.contains("<tr class=\"right\"><td style=\"padding-left:10px\">📄 only-right.txt</td>"))
        #expect(page.html.contains("<tr class=\"same\"><td style=\"padding-left:10px\">📄 same.txt</td>"))
    }

    @Test func `a merge prints the merged text escaped`() async throws {
        let root = try folder(["base.txt": "a\nb\nc\n", "left.txt": "a < 1\nb\nc\n", "right.txt": "a\nb\nc & d\n"])
        let state = AppState()
        state.mode = .merge
        state.merge.load(root.appending(path: "base.txt"), into: .base)
        state.merge.load(root.appending(path: "left.txt"), into: .left)
        state.merge.load(root.appending(path: "right.txt"), into: .right)
        for _ in 0..<400 where state.merge.merge == nil { try await Task.sleep(for: .milliseconds(10)) }
        let page = try #require(state.printPage())

        #expect(page.title == "Merge result")
        #expect(page.html.contains("<h1>Merge result</h1>a &lt; 1\nb\nc &amp; d\n</body>"))
    }
}
