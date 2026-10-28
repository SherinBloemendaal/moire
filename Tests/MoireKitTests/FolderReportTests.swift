import Foundation
@testable import MoireKit
import Testing

struct FolderReportTests {
    private func tree() throws -> (FolderTree, FolderReport.Options) {
        let base = FileManager.default.temporaryDirectory.appending(path: "moire-report-\(UUID().uuidString)")
        let left = base.appending(path: "left")
        let right = base.appending(path: "right")
        for (root, files) in [(left, ["same.txt": "s", "a <b>.txt": "1", "gone.txt": "g"]), (right, ["same.txt": "s", "a <b>.txt": "2", "new.txt": "n"])] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (name, contents) in files { try Data(contents.utf8).write(to: root.appending(path: name)) }
        }
        let tree = try FolderEngine(left: left, right: right, settings: FolderCompareSettings(method: .binary)).run()
        return (tree, FolderReport.Options(leftName: "left", rightName: "right", method: .binary))
    }

    @Test func `lists every item with a mark and a summary`() throws {
        let (tree, options) = try tree()
        let text = FolderReport.render(tree, format: .text, options: options)
        #expect(text.contains("= same.txt"))
        #expect(text.contains("≠ a <b>.txt"))
        #expect(text.contains("< gone.txt"))
        #expect(text.contains("> new.txt"))
        #expect(text.hasSuffix("1 different, 1 left only, 1 right only, 1 identical\n"))
    }

    @Test func `leaves out identical items when asked`() throws {
        var (tree, options) = try tree()
        options.onlyDifferences = true
        #expect(!FolderReport.render(tree, format: .text, options: options).contains("same.txt"))
        _ = tree
    }

    @Test func `writes JSON that programs can read`() throws {
        let (tree, options) = try tree()
        let json = FolderReport.render(tree, format: .json, options: options)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["method"] as? String == "binary")
        let summary = try #require(object["summary"] as? [String: Int])
        #expect(summary == ["different": 1, "left only": 1, "right only": 1, "identical": 1])
        let items = try #require(object["items"] as? [[String: Any]])
        let gone = try #require(items.first { $0["path"] as? String == "gone.txt" })
        #expect(gone["status"] as? String == "left only")
        #expect(gone["right"] == nil)
        #expect((gone["left"] as? [String: Any])?["size"] as? Int == 1)
    }

    @Test func `escapes names in the HTML report`() throws {
        let (tree, options) = try tree()
        let html = FolderReport.render(tree, format: .html, options: options)
        #expect(html.contains("a &lt;b&gt;.txt"))
        #expect(!html.contains("a <b>.txt"))
        #expect(html.hasPrefix("<!doctype html>"))
        #expect(FolderReport.escape("\"&<>") == "&quot;&amp;&lt;&gt;")
    }
}
