import Foundation

/// UTF-8 text that never changes, with the offset where every line starts. Documents share it
/// and refer to its lines by index, so a file with millions of lines is one block of memory
/// instead of millions of strings.
final class LineBuffer: @unchecked Sendable {
    // Everything is written once in `init` and only read afterwards, from any thread.
    private let allocation: UnsafeMutableRawBufferPointer
    let text: UnsafeBufferPointer<UInt8>
    /// `starts[i]` is where line `i` begins, including its line break; the last entry is the end
    /// of the text.
    let starts: [Int]
    let lineEnding: TextDocument.LineEnding
    let endsWithLineBreak: Bool

    var lineCount: Int { starts.count - 1 }

    /// Takes over `allocation`; the text is the `count` bytes from `offset`, and must be valid UTF-8.
    init(taking allocation: UnsafeMutableRawBufferPointer, offset: Int = 0, count: Int) {
        self.allocation = allocation
        let all = UnsafeBufferPointer(start: allocation.baseAddress?.assumingMemoryBound(to: UInt8.self), count: allocation.count)
        text = UnsafeBufferPointer(rebasing: all[offset..<(offset + count)])
        let split = LineBuffer.split(text)
        starts = split.starts
        lineEnding = split.lineEnding
        endsWithLineBreak = split.endsWithLineBreak
    }

    /// Copies valid UTF-8 bytes.
    convenience init(copying bytes: UnsafeRawBufferPointer) {
        let allocation = UnsafeMutableRawBufferPointer.allocate(byteCount: max(bytes.count, 1), alignment: 16)
        if let source = bytes.baseAddress, let destination = allocation.baseAddress {
            destination.copyMemory(from: source, byteCount: bytes.count)
        }
        self.init(taking: allocation, count: bytes.count)
    }

    deinit { allocation.deallocate() }

    /// The bytes of a line without its line break.
    @inline(__always)
    func bytes(of line: Int) -> UnsafeBufferPointer<UInt8> {
        let start = starts[line]
        var end = starts[line + 1]
        // A line never contains a break, so whatever break bytes it ends with are its terminator.
        if end > start, text[end - 1] == 0x0A { end -= 1 }
        if end > start, text[end - 1] == 0x0D { end -= 1 }
        return UnsafeBufferPointer(rebasing: text[start..<end])
    }

    func string(of line: Int) -> String {
        String(decoding: bytes(of: line), as: UTF8.self)
    }

    private struct Split {
        var starts: [Int]
        var lineEnding: TextDocument.LineEnding
        var endsWithLineBreak: Bool
    }

    /// Splits on `\r\n`, `\n` and `\r`, on several cores for big texts.
    private static func split(_ text: UnsafeBufferPointer<UInt8>) -> Split {
        let chunkSize = 1 << 22
        let chunkCount = max(1, (text.count + chunkSize - 1) / chunkSize)
        var parts = [[Int]](repeating: [], count: chunkCount)
        var counts = [(lf: Int, crlf: Int, cr: Int)](repeating: (0, 0, 0), count: chunkCount)
        parts.withUnsafeMutableBufferPointer { parts in
            counts.withUnsafeMutableBufferPointer { counts in
                Parallel.forEach(chunkCount) { chunk in
                    let range = (chunk * chunkSize)..<min(text.count, (chunk + 1) * chunkSize)
                    var ends: [Int] = []
                    ends.reserveCapacity(range.count / 24)
                    var count = (lf: 0, crlf: 0, cr: 0)
                    scanBreaks(text, range: range) { position, byte in
                        if byte == 0x0A {
                            if position > 0, text[position - 1] == 0x0D { count.crlf += 1 } else { count.lf += 1 }
                            ends.append(position + 1)
                        } else if position + 1 < text.count, text[position + 1] == 0x0A {
                            // The "\n" right after closes this "\r\n".
                        } else {
                            count.cr += 1
                            ends.append(position + 1)
                        }
                    }
                    parts[chunk] = ends
                    counts[chunk] = count
                }
            }
        }

        var starts: [Int] = [0]
        starts.reserveCapacity(parts.reduce(1) { $0 + $1.count } + 1)
        for part in parts { starts.append(contentsOf: part) }
        let endsWithLineBreak = text.count > 0 && starts.last == text.count && starts.count > 1
        if text.count > 0, !endsWithLineBreak {
            starts.append(text.count)
        }
        if text.count == 0 { starts = [0] }

        let total = counts.reduce((lf: 0, crlf: 0, cr: 0)) { ($0.lf + $1.lf, $0.crlf + $1.crlf, $0.cr + $1.cr) }
        var lineEnding = TextDocument.LineEnding.lf
        if total.crlf > total.lf, total.crlf >= total.cr { lineEnding = .crlf }
        if total.cr > total.lf, total.cr > total.crlf { lineEnding = .cr }
        return Split(starts: starts, lineEnding: lineEnding, endsWithLineBreak: endsWithLineBreak)
    }

    /// Calls `found` for every `\n` and `\r` in `range`, skipping eight bytes at a time where
    /// there are none.
    @inline(__always)
    private static func scanBreaks(_ text: UnsafeBufferPointer<UInt8>, range: Range<Int>, _ found: (Int, UInt8) -> Void) {
        guard let base = text.baseAddress else { return }
        let ones: UInt64 = 0x0101_0101_0101_0101
        let highs: UInt64 = 0x8080_8080_8080_8080
        var position = range.lowerBound
        while position < range.upperBound {
            if position + 8 <= range.upperBound {
                let word = UnsafeRawPointer(base + position).loadUnaligned(as: UInt64.self)
                let lf = word ^ (ones &* 0x0A)
                let cr = word ^ (ones &* 0x0D)
                let hasLF = (lf &- ones) & ~lf & highs
                let hasCR = (cr &- ones) & ~cr & highs
                if hasLF | hasCR == 0 {
                    position += 8
                    continue
                }
            }
            let byte = base[position]
            if byte == 0x0A || byte == 0x0D { found(position, byte) }
            position += 1
        }
    }
}

/// Runs work on every core.
enum Parallel {
    static var coreCount: Int { max(1, ProcessInfo.processInfo.activeProcessorCount) }

    static func forEach(_ count: Int, _ body: (Int) -> Void) {
        if count == 1 {
            body(0)
        } else if count > 1 {
            // Callers write to separate parts of shared buffers, which the compiler cannot see.
            nonisolated(unsafe) let body = body
            DispatchQueue.concurrentPerform(iterations: count) { body($0) }
        }
    }

    /// Splits `0..<count` into about one range per core and runs them at the same time.
    static func forEachRange(_ count: Int, minimumChunk: Int = 16_384, _ body: (Range<Int>) -> Void) {
        guard count > 0 else { return }
        let chunks = max(1, min(coreCount * 4, count / minimumChunk))
        let size = (count + chunks - 1) / chunks
        forEach(chunks) { chunk in
            let range = (chunk * size)..<min(count, (chunk + 1) * size)
            if !range.isEmpty { body(range) }
        }
    }
}

/// A fast 64-bit hash of bytes (in the style of wyhash). Equal bytes always hash the same.
enum ByteHash {
    @inline(__always)
    private static func mix(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let product = a.multipliedFullWidth(by: b)
        return product.high ^ product.low
    }

    static func hash(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt64 {
        let count = bytes.count
        var state: UInt64 = 0xA076_1D64_78BD_642F ^ UInt64(truncatingIfNeeded: count)
        guard let base = bytes.baseAddress, count > 0 else { return mix(state, 0xE703_7ED1_A0B4_28DB) }
        let raw = UnsafeRawPointer(base)
        var offset = 0
        while offset + 16 <= count {
            let a = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            let b = raw.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self)
            state = mix(a ^ 0xE703_7ED1_A0B4_28DB, b ^ state)
            offset += 16
        }
        var tail: (UInt64, UInt64) = (0, 0)
        withUnsafeMutableBytes(of: &tail) { buffer in
            buffer.copyMemory(from: UnsafeRawBufferPointer(start: raw + offset, count: count - offset))
        }
        state = mix(tail.0 ^ 0x8EBC_6AF0_9C88_C6E3, tail.1 ^ state)
        return mix(state ^ 0x5899_65CC_7537_4CC3, UInt64(truncatingIfNeeded: count) ^ 0x1D8E_4E27_C47D_124F)
    }
}

/// Checks UTF-8 without making a string, skipping eight bytes at a time over plain ASCII.
enum UTF8Validation {
    static func isValid(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let base = bytes.baseAddress else { return true }
        let count = bytes.count
        var index = 0
        while index < count {
            if index + 8 <= count, UnsafeRawPointer(base + index).loadUnaligned(as: UInt64.self) & 0x8080_8080_8080_8080 == 0 {
                index += 8
                continue
            }
            let lead = base[index]
            if lead < 0x80 {
                index += 1
                continue
            }
            let length: Int
            var low: UInt8 = 0x80
            var high: UInt8 = 0xBF
            switch lead {
            case 0xC2...0xDF: length = 2
            case 0xE0: length = 3; low = 0xA0
            case 0xE1...0xEC, 0xEE...0xEF: length = 3
            case 0xED: length = 3; high = 0x9F
            case 0xF0: length = 4; low = 0x90
            case 0xF1...0xF3: length = 4
            case 0xF4: length = 4; high = 0x8F
            default: return false
            }
            guard index + length <= count else { return false }
            let second = base[index + 1]
            guard second >= low, second <= high else { return false }
            for offset in 2..<max(2, length) where base[index + offset] & 0xC0 != 0x80 {
                return false
            }
            index += length
        }
        return true
    }
}
