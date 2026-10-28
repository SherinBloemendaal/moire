/// Numbers every line so that lines that count as equal under the options get the same number:
/// the position of the first such line, counting the left lines first and then the right ones.
/// Myers then compares integers instead of text.
///
/// Lines are hashed on every core, then each core takes a share of the hashes and checks every
/// match byte for byte, so two different lines never share a number.
enum LineInterner {
    static func ids(_ left: Lines, _ right: Lines, options: DiffOptions) -> (left: [Int], right: [Int]) {
        let leftCount = left.count
        let total = leftCount + right.count
        guard total > 0 else { return ([], []) }

        var hashes = [UInt64](repeating: 0, count: total)
        hashes.withUnsafeMutableBufferPointer { hashes in
            Parallel.forEachRange(total) { range in
                var scratch: [UInt8] = []
                let leftPart = range.clamped(to: 0..<leftCount)
                left.forEachLine(in: leftPart) { index, bytes in
                    hashes[index] = LineKey.with(bytes, options, &scratch) { ByteHash.hash($0) }
                }
                let rightPart = (max(range.lowerBound, leftCount) - leftCount)..<(max(range.upperBound, leftCount) - leftCount)
                right.forEachLine(in: rightPart) { index, bytes in
                    hashes[leftCount + index] = LineKey.with(bytes, options, &scratch) { ByteHash.hash($0) }
                }
            }
        }

        func withLine<R>(_ index: Int, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
            index < leftCount ? left.withBytes(of: index, body) : right.withBytes(of: index - leftCount, body)
        }

        var ids = [Int](repeating: 0, count: total)
        let shardCount = total < 65_536 ? 1 : Parallel.coreCount * 2
        hashes.withUnsafeBufferPointer { hashes in
            ids.withUnsafeMutableBufferPointer { ids in
                Parallel.forEach(shardCount) { shard in
                    var table = Table(expected: total / shardCount + 16)
                    var first: [UInt8] = []
                    var second: [UInt8] = []
                    for index in 0..<total {
                        let hash = hashes[index]
                        guard shardCount == 1 || Int(truncatingIfNeeded: hash >> 40) % shardCount == shard else { continue }
                        ids[index] = table.intern(hash: hash, index: index) { candidate in
                            withLine(index) { line in
                                withLine(candidate) { other in
                                    LineKey.with(line, options, &first) { a in LineKey.with(other, options, &second) { b in a.elementsEqual(b) } }
                                }
                            }
                        }
                    }
                }
            }
        }
        return (Array(ids[0..<leftCount]), Array(ids[leftCount...]))
    }

    /// Open addressing from hash to the first line with that key. Lines whose hash is equal but
    /// whose text is not simply take the next free slot.
    private struct Table {
        private var hashes: [UInt64]
        private var lines: [Int]
        private var used = 0
        private var mask: Int

        init(expected: Int) {
            var capacity = 16
            while capacity < expected * 2 { capacity <<= 1 }
            hashes = [UInt64](repeating: 0, count: capacity)
            lines = [Int](repeating: -1, count: capacity)
            mask = capacity - 1
        }

        mutating func intern(hash: UInt64, index: Int, isEqual: (Int) -> Bool) -> Int {
            var slot = Int(truncatingIfNeeded: hash) & mask
            while lines[slot] >= 0 {
                if hashes[slot] == hash, isEqual(lines[slot]) { return lines[slot] }
                slot = (slot + 1) & mask
            }
            hashes[slot] = hash
            lines[slot] = index
            used += 1
            if used * 2 > lines.count { grow() }
            return index
        }

        private mutating func grow() {
            let oldHashes = hashes
            let oldLines = lines
            let capacity = lines.count * 2
            hashes = [UInt64](repeating: 0, count: capacity)
            lines = [Int](repeating: -1, count: capacity)
            mask = capacity - 1
            for (hash, line) in zip(oldHashes, oldLines) where line >= 0 {
                var slot = Int(truncatingIfNeeded: hash) & mask
                while lines[slot] >= 0 { slot = (slot + 1) & mask }
                hashes[slot] = hash
                lines[slot] = line
            }
        }
    }
}

/// What is left of a line once the options have had their say: without the spaces that do not
/// count, and in lower case when case does not count.
enum LineKey {
    @inline(__always)
    static func with<R>(_ line: UnsafeBufferPointer<UInt8>, _ options: DiffOptions, _ scratch: inout [UInt8], _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        if options.whitespace == .exact, !options.ignoreCase { return body(line) }

        var start = 0
        var end = line.count
        if options.whitespace == .ignoreLeadingAndTrailing {
            while start < end, line[start] == 0x20 || line[start] == 0x09 { start += 1 }
            while end > start, line[end - 1] == 0x20 || line[end - 1] == 0x09 { end -= 1 }
        }
        scratch.removeAll(keepingCapacity: true)
        var isASCII = true
        for index in start..<end {
            let byte = line[index]
            if options.whitespace == .ignoreAll, byte == 0x20 || byte == 0x09 { continue }
            if byte >= 0x80 { isASCII = false }
            scratch.append(options.ignoreCase && byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte)
        }
        if options.ignoreCase, !isASCII {
            let lowered = String(decoding: scratch, as: UTF8.self).lowercased()
            scratch.removeAll(keepingCapacity: true)
            scratch.append(contentsOf: lowered.utf8)
        }
        return scratch.withUnsafeBufferPointer(body)
    }
}
