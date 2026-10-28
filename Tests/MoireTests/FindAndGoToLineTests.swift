import Foundation
@testable import Moire
import MoireKit
import Testing

/// Find in both documents and Go to Line, through the compare model.
@MainActor
struct FindAndGoToLineTests {
    private func compared(_ left: String, _ right: String) async throws -> (CompareModel, LineDiff) {
        let model = CompareModel()
        model.setText(left, on: .left)
        model.setText(right, on: .right)
        for _ in 0..<400 where model.isComputing || model.diff?.left.text != left || model.diff?.right.text != right {
            try await Task.sleep(for: .milliseconds(5))
        }
        return (model, try #require(model.diff))
    }

    private func search(_ query: String, in model: CompareModel) async throws -> SearchResults {
        model.showSearch()
        model.searchQuery = query
        for _ in 0..<400 where model.searchResults == nil || model.isSearching { try await Task.sleep(for: .milliseconds(5)) }
        return try #require(model.searchResults)
    }

    private func sidesAndLines(_ matches: [SearchMatch]) -> [String] {
        matches.map { "\($0.side.name) \($0.line)" }
    }

    @Test func `matches of both sides are merged in row order, left first on a shared row`() async throws {
        let (model, diff) = try await compared("a x\nb\nc\nd x\n", "a x\nb x\nc\nd x\n")
        let results = try await search("x", in: model)

        #expect(sidesAndLines(results.ordered) == ["Left 0", "Right 0", "Right 1", "Left 3", "Right 3"])
        let expectedRows = results.ordered.map { diff.row(ofLine: $0.line, on: $0.side) }
        #expect(results.rows == expectedRows)
        #expect(results.rows == results.rows.sorted())
        #expect(model.searchMatchCount == 5)
    }

    @Test func `typing a query jumps to the first match`() async throws {
        let (model, _) = try await compared("one\nfind me\n", "one\nfind me too\n")
        let results = try await search("find", in: model)

        #expect(model.currentMatch == 0)
        let request = try #require(model.scrollRequest)
        #expect(request.row == results.rows[0])
        #expect(request.side == .left)
        #expect(request.match == results.ordered[0])
    }

    @Test func `next and previous step through the matches and wrap around`() async throws {
        let (model, _) = try await compared("x\nkeep\nx\n", "x\nkeep\ny\n")
        let results = try await search("x", in: model)
        #expect(results.ordered.count == 3)
        #expect(model.currentMatch == 0)

        model.findNext()
        #expect(model.currentMatch == 1)
        model.findNext()
        #expect(model.currentMatch == 2)
        #expect(model.scrollRequest?.match == results.ordered[2])
        model.findNext()
        #expect(model.currentMatch == 0)
        model.findPrevious()
        #expect(model.currentMatch == 2)
        #expect(model.scrollRequest?.row == results.rows[2])
        model.findPrevious()
        #expect(model.currentMatch == 1)
    }

    @Test func `a query that matches nothing has no current match and Next keeps it so`() async throws {
        let (model, _) = try await compared("a\n", "b\n")
        let results = try await search("zzz", in: model)
        #expect(results.ordered.isEmpty)
        #expect(model.currentMatch == nil)
        model.findNext()
        #expect(model.currentMatch == nil)
    }

    @Test func `go to line scrolls to the row of that line on the chosen side and marks it`() async throws {
        let (model, diff) = try await compared("a\nb\nc\n", "a\nnew\nb\nc\n")

        model.goToLine(3, on: .right)
        let request = try #require(model.scrollRequest)
        #expect(request.row == diff.row(ofLine: 2, on: .right))
        #expect(request.side == .right)
        #expect(model.flashedLine?.side == .right)
        #expect(model.flashedLine?.line == 2)

        model.goToLine(3, on: .left)
        #expect(model.scrollRequest?.row == diff.row(ofLine: 2, on: .left))
        #expect(model.scrollRequest?.id == request.id + 1)
    }

    @Test func `go to line keeps the number within the document`() async throws {
        let (model, diff) = try await compared("a\nb\nc\n", "a\nb\nc\n")

        model.goToLine(99, on: .left)
        #expect(model.flashedLine?.line == 2)
        #expect(model.scrollRequest?.row == diff.row(ofLine: 2, on: .left))

        model.goToLine(0, on: .left)
        #expect(model.flashedLine?.line == 0)
        #expect(model.scrollRequest?.row == diff.row(ofLine: 0, on: .left))
    }

    @Test func `go to line unfolds the unchanged lines that hide it`() async throws {
        let previous = UserDefaults.standard.object(forKey: "onlyChanges")
        defer { UserDefaults.standard.set(previous, forKey: "onlyChanges") }
        let lines = (1...60).map { "line \($0)" }
        var changed = lines
        changed[0] = "changed"
        let (model, diff) = try await compared(lines.joined(separator: "\n") + "\n", changed.joined(separator: "\n") + "\n")
        model.onlyChanges = true
        let row = diff.row(ofLine: 40, on: .left)
        #expect(model.display?.fold(containingRow: row) != nil)

        model.goToLine(41, on: .left)
        #expect(model.display?.fold(containingRow: row) == nil)
        #expect(model.scrollRequest?.row == row)
    }
}
