import Foundation

/// Where a search found the text: a line of one side, and the place in that line in UTF-16
/// units (what AppKit text uses).
public struct SearchMatch: Sendable, Hashable {
    public var side: DiffSide
    public var line: Int
    public var range: Range<Int>

    public init(side: DiffSide, line: Int, range: Range<Int>) {
        self.side = side
        self.line = line
        self.range = range
    }
}

/// Finds text in the lines of a document, on every core. Matches do not overlap.
public enum TextSearch {
    public static func matches(of query: String, in lines: Lines, side: DiffSide, caseSensitive: Bool) -> [SearchMatch] {
        guard !query.isEmpty, !lines.isEmpty else { return [] }
        let needle = Array(query.utf8)
        let isASCII = needle.allSatisfy { $0 < 0x80 }
        let folded = caseSensitive ? needle : needle.map(lower)

        let chunks = max(1, min(Parallel.coreCount * 4, lines.count / 8192))
        let size = (lines.count + chunks - 1) / chunks
        var parts = [[SearchMatch]](repeating: [], count: chunks)
        parts.withUnsafeMutableBufferPointer { parts in
            Parallel.forEach(chunks) { chunk in
                var found: [SearchMatch] = []
                lines.forEachLine(in: (chunk * size)..<min(lines.count, (chunk + 1) * size)) { line, bytes in
                    if caseSensitive || isASCII {
                        searchBytes(bytes, folded, foldCase: !caseSensitive) { start in
                            let offset = utf16Offset(bytes, start)
                            found.append(SearchMatch(side: side, line: line, range: offset..<(offset + utf16Length(bytes, start, needle.count))))
                        }
                    } else {
                        let text = String(decoding: bytes, as: UTF8.self)
                        var from = text.startIndex
                        while from < text.endIndex, let range = text.range(of: query, options: [.caseInsensitive], range: from..<text.endIndex) {
                            let start = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
                            found.append(SearchMatch(side: side, line: line, range: start..<(start + text.utf16.distance(from: range.lowerBound, to: range.upperBound))))
                            from = range.isEmpty ? text.index(after: range.upperBound) : range.upperBound
                        }
                    }
                }
                parts[chunk] = found
            }
        }
        return parts.flatMap { $0 }
    }

    @inline(__always)
    private static func lower(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte
    }

    private static func searchBytes(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: [UInt8], foldCase: Bool, found: (Int) -> Void) {
        let count = needle.count
        guard haystack.count >= count, let first = needle.first else { return }
        var index = 0
        let last = haystack.count - count
        while index <= last {
            let byte = foldCase ? lower(haystack[index]) : haystack[index]
            guard byte == first else {
                index += 1
                continue
            }
            var offset = 1
            while offset < count, (foldCase ? lower(haystack[index + offset]) : haystack[index + offset]) == needle[offset] {
                offset += 1
            }
            if offset == count {
                found(index)
                index += count
            } else {
                index += 1
            }
        }
    }

    /// UTF-16 units in the first `byteCount` bytes of UTF-8.
    private static func utf16Offset(_ bytes: UnsafeBufferPointer<UInt8>, _ byteCount: Int) -> Int {
        utf16Length(bytes, 0, byteCount)
    }

    private static func utf16Length(_ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ count: Int) -> Int {
        var units = 0
        for index in start..<(start + count) {
            let byte = bytes[index]
            // Every byte that starts a character counts one, a four-byte character two.
            if byte & 0xC0 != 0x80 { units += 1 }
            if byte >= 0xF0 { units += 1 }
        }
        return units
    }
}
