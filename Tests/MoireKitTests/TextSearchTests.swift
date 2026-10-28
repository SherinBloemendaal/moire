import Foundation
@testable import MoireKit
import Testing

struct TextSearchTests {
    private func ranges(_ query: String, _ text: String, caseSensitive: Bool = false) -> [String] {
        let document = TextDocument(text)
        return TextSearch.matches(of: query, in: document.lines, side: .left, caseSensitive: caseSensitive).map { match in
            let line = document.lines[match.line] as NSString
            return "\(match.line):" + line.substring(with: NSRange(location: match.range.lowerBound, length: match.range.count))
        }
    }

    @Test func `finds every match in every line without overlaps`() {
        #expect(ranges("aa", "aaaa\nbaab\nnone") == ["0:aa", "0:aa", "1:aa"])
    }

    @Test func `ignores case unless asked not to`() {
        #expect(ranges("total", "Total = TOTAL + total") == ["0:Total", "0:TOTAL", "0:total"])
        #expect(ranges("total", "Total = TOTAL + total", caseSensitive: true) == ["0:total"])
    }

    @Test func `reports places in UTF-16 units after other characters`() {
        #expect(ranges("x", "😀é x") == ["0:x"])
        let match = TextSearch.matches(of: "x", in: TextDocument("😀é x").lines, side: .right, caseSensitive: false)
        #expect(match == [SearchMatch(side: .right, line: 0, range: 4..<5)])
    }

    @Test func `finds text that is not ASCII, with and without case`() {
        #expect(ranges("émile", "Émile et émile") == ["0:Émile", "0:émile"])
        #expect(ranges("émile", "Émile et émile", caseSensitive: true) == ["0:émile"])
        #expect(ranges("😀", "a😀b😀") == ["0:😀", "0:😀"])
    }

    @Test func `searches big documents on several cores in line order`() {
        let document = TextDocument((0..<100_000).map { $0 % 1000 == 0 ? "needle \($0)\n" : "hay \($0)\n" }.joined())
        let matches = TextSearch.matches(of: "NEEDLE", in: document.lines, side: .left, caseSensitive: false)
        #expect(matches.count == 100)
        #expect(matches.map(\.line) == Array(stride(from: 0, to: 100_000, by: 1000)))
    }
}
