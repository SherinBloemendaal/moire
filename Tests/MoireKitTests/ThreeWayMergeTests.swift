import Foundation
@testable import MoireKit
import Testing

private func merge(_ base: String, _ left: String, _ right: String) -> ThreeWayMerge {
    ThreeWayMerge(base: TextDocument(base), left: TextDocument(left), right: TextDocument(right))
}

private func kinds(_ merge: ThreeWayMerge) -> [ThreeWayMerge.Chunk.Kind] {
    merge.chunks.map(\.kind)
}

@Suite struct ThreeWayMergeTests {
    @Test func `identical inputs give one unchanged chunk and the same text`() {
        let text = "one\ntwo\nthree\n"
        let result = merge(text, text, text)
        #expect(kinds(result) == [.unchanged])
        #expect(result.conflicts.isEmpty)
        #expect(result.result([:]).text == text)
    }

    @Test func `a change on the left only is taken`() {
        let result = merge("a\nb\nc\n", "a\nB\nc\n", "a\nb\nc\n")
        #expect(kinds(result) == [.unchanged, .changedLeft, .unchanged])
        #expect(result.result([:]).text == "a\nB\nc\n")
    }

    @Test func `a change on the right only is taken`() {
        let result = merge("a\nb\nc\n", "a\nb\nc\n", "a\nb\nC\nd\n")
        #expect(kinds(result) == [.unchanged, .changedRight])
        #expect(result.result([:]).text == "a\nb\nC\nd\n")
    }

    @Test func `changes on both sides in different places merge without a conflict`() {
        let result = merge("1\n2\n3\n4\n5\n", "one\n2\n3\n4\n5\n", "1\n2\n3\n4\nfive\n")
        #expect(kinds(result) == [.changedLeft, .unchanged, .changedRight])
        #expect(result.conflicts.isEmpty)
        #expect(result.result([:]).text == "one\n2\n3\n4\nfive\n")
    }

    @Test func `the same change on both sides is no conflict`() {
        let result = merge("a\nb\nc\n", "a\nX\nc\n", "a\nX\nc\n")
        #expect(kinds(result) == [.unchanged, .changedBoth, .unchanged])
        #expect(result.conflicts.isEmpty)
        #expect(result.result([:]).text == "a\nX\nc\n")
    }

    @Test func `different changes to the same line are a conflict with diff3 markers`() {
        let result = merge("a\nb\nc\n", "a\nleft\nc\n", "a\nright\nc\n")
        #expect(kinds(result) == [.unchanged, .conflict, .unchanged])
        #expect(result.conflicts == [1])
        #expect(result.unresolvedConflicts([:]) == [1])
        let labels = ThreeWayMerge.Labels(left: "ours", base: "base", right: "theirs")
        #expect(result.result([:], labels: labels).text == """
        a
        <<<<<<< ours
        left
        ||||||| base
        b
        =======
        right
        >>>>>>> theirs
        c

        """)
    }

    @Test func `a conflict resolves to either side, both in either order, the base or typed text`() {
        let result = merge("a\nb\nc\n", "a\nleft\nc\n", "a\nright\nc\n")
        let cases: [(ThreeWayMerge.Resolution, String)] = [
            (.left, "a\nleft\nc\n"),
            (.right, "a\nright\nc\n"),
            (.leftThenRight, "a\nleft\nright\nc\n"),
            (.rightThenLeft, "a\nright\nleft\nc\n"),
            (.base, "a\nb\nc\n"),
            (.edited(text: "mine\nyours\n"), "a\nmine\nyours\nc\n"),
            (.edited(text: ""), "a\nc\n"),
        ]
        for (resolution, expected) in cases {
            #expect(result.result([1: resolution]).text == expected)
            #expect(result.unresolvedConflicts([1: resolution]).isEmpty)
        }
    }

    @Test func `a resolution can also override a chunk that merged by itself`() {
        let result = merge("a\nb\nc\n", "a\nB\nc\n", "a\nb\nc\n")
        #expect(result.result([1: .base]).text == "a\nb\nc\n")
        #expect(result.result([0: .edited(text: "first\n")]).text == "first\nB\nc\n")
    }

    @Test func `changes on adjacent lines are one conflict`() {
        // With no line in between that all three agree on, the order of the two edits is not
        // known, so like diff3 and git this is a conflict.
        let result = merge("1\n2\n3\n4\n", "1\nTWO\n3\n4\n", "1\n2\nTHREE\n4\n")
        #expect(kinds(result) == [.unchanged, .conflict, .unchanged])
        let chunk = result.chunks[1]
        #expect(chunk.base == 1..<3)
        #expect(result.lines(of: .left, in: 1).map(\.text) == ["TWO", "3"])
        #expect(result.lines(of: .right, in: 1).map(\.text) == ["2", "THREE"])
    }

    @Test func `changes with one shared line between them merge cleanly`() {
        let result = merge("1\n2\n3\n4\n5\n", "1\nTWO\n3\n4\n5\n", "1\n2\n3\nFOUR\n5\n")
        #expect(kinds(result) == [.unchanged, .changedLeft, .unchanged, .changedRight, .unchanged])
        #expect(result.result([:]).text == "1\nTWO\n3\nFOUR\n5\n")
    }

    @Test func `an insert at the start on one side is taken`() {
        let result = merge("a\nb\n", "new\na\nb\n", "a\nb\n")
        #expect(kinds(result) == [.changedLeft, .unchanged])
        #expect(result.chunks[0].base.isEmpty)
        #expect(result.result([:]).text == "new\na\nb\n")
    }

    @Test func `different inserts at the start on both sides conflict`() {
        let result = merge("a\nb\n", "left\na\nb\n", "right\na\nb\n")
        #expect(kinds(result) == [.conflict, .unchanged])
        #expect(result.result([0: .leftThenRight]).text == "left\nright\na\nb\n")
    }

    @Test func `inserts at the end merge, and different ones conflict`() {
        let oneSided = merge("a\nb\n", "a\nb\n", "a\nb\nc\n")
        #expect(kinds(oneSided) == [.unchanged, .changedRight])
        #expect(oneSided.result([:]).text == "a\nb\nc\n")

        let bothSides = merge("a\nb\n", "a\nb\nx\n", "a\nb\ny\n")
        #expect(kinds(bothSides) == [.unchanged, .conflict])
        #expect(bothSides.chunks[1].base.isEmpty)
        #expect(bothSides.result([1: .rightThenLeft]).text == "a\nb\ny\nx\n")
    }

    @Test func `an insert at the start and one at the end both make it`() {
        let result = merge("a\nb\n", "start\na\nb\n", "a\nb\nend\n")
        #expect(kinds(result) == [.changedLeft, .unchanged, .changedRight])
        #expect(result.result([:]).text == "start\na\nb\nend\n")
    }

    @Test func `a deletion against an edit of the same line conflicts`() {
        let result = merge("a\nb\nc\n", "a\nc\n", "a\nB\nc\n")
        #expect(kinds(result) == [.unchanged, .conflict, .unchanged])
        #expect(result.lines(of: .left, in: 1).isEmpty)
        #expect(result.result([1: .left]).text == "a\nc\n")
    }

    @Test func `empty files`() {
        let allEmpty = merge("", "", "")
        #expect(allEmpty.chunks.isEmpty)
        #expect(allEmpty.result([:]).text == "")

        let addedLeft = merge("", "new\n", "")
        #expect(kinds(addedLeft) == [.changedLeft])
        #expect(addedLeft.result([:]).text == "new\n")

        let addedBoth = merge("", "x\n", "y\n")
        #expect(kinds(addedBoth) == [.conflict])

        let emptiedRight = merge("a\nb\n", "a\nb\n", "")
        #expect(kinds(emptiedRight) == [.changedRight])
        #expect(emptiedRight.result([:]).text == "")
    }

    @Test func `CRLF line endings are kept in the result`() {
        let result = merge("a\r\nb\r\nc\r\n", "a\r\nB\r\nc\r\n", "a\r\nb\r\nc\r\nd\r\n")
        #expect(result.lineEnding == .crlf)
        #expect(result.result([:]).text == "a\r\nB\r\nc\r\nd\r\n")
        #expect(result.result([:]).text.contains("\r\n<<<<<<<") == false)
    }

    @Test func `conflict markers use the CRLF line ending of the file`() {
        let result = merge("a\r\nb\r\n", "a\r\nL\r\n", "a\r\nR\r\n")
        #expect(result.result([:]).text == "a\r\n<<<<<<< LEFT\r\nL\r\n||||||| BASE\r\nb\r\n=======\r\nR\r\n>>>>>>> RIGHT\r\n")
    }

    @Test func `a missing line break at the end is kept or changed like any other edit`() {
        let kept = merge("a\nb", "A\nb", "a\nb")
        #expect(kept.result([:]).text == "A\nb")

        let added = merge("a\nx\nb", "a\nx\nb\n", "A\nx\nb")
        #expect(kinds(added) == [.changedRight, .unchanged, .changedLeft])
        #expect(added.result([:]).text == "A\nx\nb\n")
    }

    @Test func `both sides of a conflict at the end without a line break keep the markers on their own lines`() {
        let result = merge("a\nb", "a\nleft", "a\nright")
        #expect(result.result([:]).text == "a\n<<<<<<< LEFT\nleft\n||||||| BASE\nb\n=======\nright\n>>>>>>> RIGHT\n")
        #expect(result.result([1: .left]).text == "a\nleft")
        #expect(result.result([1: .leftThenRight]).text == "a\nleft\nright")
    }

    @Test func `the merged text is written back in the encoding of the left file`() throws {
        let encoding = TextEncoding(encoding: .utf16LittleEndian, byteOrderMark: true)
        func document(_ text: String) throws -> (TextDocument, TextEncoding) {
            guard case .text(let document, let encoding) = FileContent.decode(try encoding.encode(text)) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (document, encoding)
        }
        let (base, _) = try document("één\r\ndrie\r\ntwee\r\n")
        let (left, leftEncoding) = try document("één\r\ndrie\r\nTWEE\r\n")
        let (right, _) = try document("een\r\ndrie\r\ntwee\r\n")
        let merged = ThreeWayMerge(base: base, left: left, right: right).result([:])
        #expect(leftEncoding == encoding)
        #expect(try leftEncoding.encode(merged.text) == encoding.encode("een\r\ndrie\r\nTWEE\r\n"))
    }

    @Test func `with one side untouched the result is the other side`() {
        var generator = SplitMix(seed: 7)
        for _ in 0..<300 {
            let base = randomText(&generator)
            let changed = randomText(&generator)
            #expect(merge(base, base, changed).result([:]).text == TextDocument(changed).text)
            #expect(merge(base, changed, base).result([:]).text == TextDocument(changed).text)
            #expect(merge(base, changed, changed).conflicts.isEmpty)
        }
    }

    @Test func `chunks cover every line of all three versions in order`() {
        var generator = SplitMix(seed: 42)
        for _ in 0..<300 {
            let result = merge(randomText(&generator), randomText(&generator), randomText(&generator))
            var b = 0, l = 0, r = 0
            for chunk in result.chunks {
                #expect(chunk.base.lowerBound == b && chunk.left.lowerBound == l && chunk.right.lowerBound == r)
                b = chunk.base.upperBound; l = chunk.left.upperBound; r = chunk.right.upperBound
            }
            #expect(b == result.base.count && l == result.left.count && r == result.right.count)
            // Taking the left side everywhere gives back the left file.
            let allLeft = Dictionary(uniqueKeysWithValues: result.chunks.indices.map { ($0, ThreeWayMerge.Resolution.left) })
            #expect(result.resultLines(allLeft) == result.left)
        }
    }
}

/// A small seeded generator, so the random cases are the same on every run.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Up to a dozen lines from a small alphabet, so lines repeat and match in many ways.
func randomText(_ generator: inout SplitMix) -> String {
    let count = Int.random(in: 0...12, using: &generator)
    let lines = (0..<count).map { _ in ["a", "b", "c", "d", ""].randomElement(using: &generator) ?? "a" }
    let ending = Bool.random(using: &generator) ? "\n" : ""
    return lines.joined(separator: "\n") + (lines.isEmpty ? "" : ending)
}
