import Foundation
@testable import MoireKit
import Testing

/// Checks that the bytes between hunks really are the same on both sides and line up, and that
/// the hunks cover both files up to their ends.
private func isConsistent(_ diff: ByteDiff, _ a: [UInt8], _ b: [UInt8]) -> Bool {
    var l = 0
    var r = 0
    for hunk in diff.hunks {
        guard hunk.left.lowerBound >= l, hunk.right.lowerBound >= r else { return false }
        guard hunk.left.lowerBound - l == hunk.right.lowerBound - r else { return false }
        guard a[l..<hunk.left.lowerBound] == b[r..<hunk.right.lowerBound] else { return false }
        guard !hunk.left.isEmpty || !hunk.right.isEmpty else { return false }
        l = hunk.left.upperBound
        r = hunk.right.upperBound
    }
    return a.count - l == b.count - r && a[l...] == b[r...]
}

private func randomBytes(_ count: Int, seed: UInt64) -> [UInt8] {
    var state = seed
    return (0..<count).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return UInt8(truncatingIfNeeded: state >> 33)
    }
}

private func compare(_ a: [UInt8], _ b: [UInt8], _ options: ByteDiff.Options = ByteDiff.Options()) throws -> ByteDiff {
    try ByteDiff.compare(DataByteSource(Data(a)), DataByteSource(Data(b)), options: options)
}

@Suite struct ByteDiffTests {
    @Test func `identical files have no differences`() throws {
        let bytes = randomBytes(10_000, seed: 1)
        let diff = try compare(bytes, bytes)
        #expect(diff.isIdentical)
        #expect(diff.alignment == .byOffset)
    }

    @Test func `empty files are identical`() throws {
        #expect(try compare([], []).isIdentical)
    }

    @Test func `same size files are compared by offset`() throws {
        var b = randomBytes(5000, seed: 2)
        let a = b
        b[10] ^= 0xFF
        b[4000] ^= 0x01
        b[4003] ^= 0x01
        let diff = try compare(a, b)
        #expect(diff.alignment == .byOffset)
        #expect(diff.hunks == [ByteHunk(left: 10..<11, right: 10..<11), ByteHunk(left: 4000..<4004, right: 4000..<4004)])
        #expect(isConsistent(diff, a, b))
    }

    @Test func `differences far apart stay separate`() throws {
        var b = [UInt8](repeating: 7, count: 100)
        let a = b
        b[0] = 1
        b[50] = 1
        let diff = try compare(a, b)
        #expect(diff.hunks.count == 2)
    }

    @Test func `a small insertion lines the rest up again`() throws {
        let a = randomBytes(20_000, seed: 3)
        var b = a
        b.insert(contentsOf: [1, 2, 3, 4, 5], at: 7000)
        let diff = try compare(a, b)
        #expect(diff.alignment == .aligned)
        #expect(isConsistent(diff, a, b))
        #expect(diff.hunks.count == 1)
        #expect(diff.leftChangedBytes == 0)
        #expect(diff.rightChangedBytes == 5)
    }

    @Test func `a small removal lines the rest up again`() throws {
        let a = randomBytes(20_000, seed: 4)
        var b = a
        b.removeSubrange(300..<310)
        let diff = try compare(a, b)
        #expect(isConsistent(diff, a, b))
        #expect(diff.hunks == [ByteHunk(left: 300..<310, right: 300..<300)])
    }

    @Test func `a large insertion is found by searching ahead`() throws {
        let a = randomBytes(200_000, seed: 5)
        var b = a
        b.insert(contentsOf: randomBytes(50_000, seed: 6), at: 100_000)
        let diff = try compare(a, b)
        #expect(diff.alignment == .aligned)
        #expect(isConsistent(diff, a, b))
        #expect(diff.hunks.count == 1)
        #expect(diff.leftChangedBytes == 0)
        #expect(diff.rightChangedBytes == 50_000)
    }

    @Test func `a replaced block followed by an insertion lines up`() throws {
        let a = randomBytes(50_000, seed: 7)
        var b = a
        b.replaceSubrange(1000..<1100, with: randomBytes(100, seed: 8))
        b.insert(contentsOf: randomBytes(3000, seed: 9), at: 30_000)
        let diff = try compare(a, b)
        #expect(isConsistent(diff, a, b))
        #expect(diff.hunks.count == 2)
        #expect(diff.rightChangedBytes - diff.leftChangedBytes == 3000)
    }

    @Test func `a changed tail is compared exactly`() throws {
        let a: [UInt8] = Array("the same start, then AXYZ".utf8)
        let b: [UInt8] = Array("the same start, then BXYZW".utf8)
        var options = ByteDiff.Options()
        options.mergeGap = 0
        let diff = try compare(a, b, options)
        #expect(isConsistent(diff, a, b))
        #expect(diff.hunks == [ByteHunk(left: 21..<22, right: 21..<22), ByteHunk(left: 25..<25, right: 25..<26)])
        // With the default gap the two are shown as one.
        #expect(try compare(a, b).hunks == [ByteHunk(left: 21..<25, right: 21..<26)])
    }

    @Test func `unrelated files fall back to offsets and say where`() throws {
        let a = randomBytes(300_000, seed: 10)
        let b = randomBytes(310_000, seed: 11)
        var options = ByteDiff.Options()
        options.maximumFailedSyncs = 8
        let diff = try compare(a, b, options)
        guard case .alignedUntil(let left, let right) = diff.alignment else {
            Issue.record("expected the alignment to give up, got \(diff.alignment)")
            return
        }
        #expect(left == right)
        #expect(isConsistent(diff, a, b))
    }

    @Test func `by offset never looks for insertions`() throws {
        let a = randomBytes(1000, seed: 12)
        var b = a
        b.insert(9, at: 0)
        let diff = try compare(a, b, ByteDiff.Options(matching: .byOffset))
        #expect(diff.alignment == .byOffset)
        #expect(isConsistent(diff, a, b))
        #expect(diff.hunks.count == 1)
        #expect(diff.hunks[0].left.lowerBound < 10)
        #expect(diff.hunks[0].right.upperBound == 1001)
    }

    @Test func `finding insertions also works for files of the same size`() throws {
        let a = randomBytes(10_000, seed: 13)
        var b = a
        b.remove(at: 100)
        b.insert(1, at: 9000)
        let diff = try compare(a, b, ByteDiff.Options(matching: .findInsertions))
        #expect(diff.alignment == .aligned)
        #expect(isConsistent(diff, a, b))
        #expect(diff.hunks.count == 2)
    }

    @Test func `chunk borders do not matter`() throws {
        var options = ByteDiff.Options()
        options.chunkSize = 7
        let a = randomBytes(4000, seed: 14)
        var b = a
        b.insert(contentsOf: [1, 2], at: 1234)
        b[3000] ^= 0x10
        let diff = try compare(a, b, options)
        #expect(isConsistent(diff, a, b))
        #expect(diff.hunks.count == 2)
    }

    @Test func `one empty file is one difference`() throws {
        let a = randomBytes(100, seed: 15)
        let diff = try compare(a, [])
        #expect(diff.hunks == [ByteHunk(left: 0..<100, right: 0..<0)])
    }

    @Test func `a cancelled comparison stops`() async throws {
        let a = randomBytes(100_000, seed: 16)
        let b = randomBytes(100_000, seed: 17)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try compare(a, b)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func `files are read in pages`() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "moire-bytes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = randomBytes(10_000, seed: 18)
        try Data(bytes).write(to: url)
        let source = try FileByteSource(url: url, pageSize: 100, maximumPages: 3)
        #expect(source.count == 10_000)
        #expect(try source.bytes(in: 95..<305) == Array(bytes[95..<305]))
        #expect(try source.bytes(in: 9990..<20_000) == Array(bytes[9990...]))
        #expect(try source.bytes(in: 0..<10) == Array(bytes[0..<10]))
        #expect(try source.bytes(in: 20_000..<20_010).isEmpty)
    }
}

@Suite struct HexLayoutTests {
    @Test func `same size files use rows at fixed offsets`() throws {
        var b = randomBytes(100, seed: 20)
        let a = b
        b[40] ^= 1
        let layout = HexLayout(diff: try compare(a, b), bytesPerRow: 16)
        #expect(layout.rowCount == 7)
        #expect(layout.row(0) == HexLayout.Row(left: 0..<16, right: 0..<16, hunk: nil))
        #expect(layout.row(2) == HexLayout.Row(left: 32..<48, right: 32..<48, hunk: 0))
        #expect(layout.row(6) == HexLayout.Row(left: 96..<100, right: 96..<100, hunk: nil))
        #expect(layout.firstRow(ofHunk: 0) == 2)
    }

    @Test func `a longer right file shows its tail alone`() throws {
        let a = randomBytes(20, seed: 21)
        let b = a + randomBytes(20, seed: 22)
        let layout = HexLayout(diff: try compare(a, b), bytesPerRow: 16)
        #expect(layout.rowCount == 3)
        #expect(layout.row(1) == HexLayout.Row(left: 16..<20, right: 16..<32, hunk: 0))
        #expect(layout.row(2) == HexLayout.Row(left: 20..<20, right: 32..<40, hunk: 0))
    }

    @Test func `an insertion gets rows of its own and the rest lines up`() throws {
        let a = randomBytes(64, seed: 23)
        var b = a
        b.insert(contentsOf: randomBytes(20, seed: 24), at: 32)
        let diff = try compare(a, b)
        let layout = HexLayout(diff: diff, bytesPerRow: 16)
        #expect(diff.hunks.count == 1)
        let hunkRow = layout.firstRow(ofHunk: 0)
        let inserted = layout.row(hunkRow)
        #expect(inserted.hunk == 0)
        #expect(inserted.left.isEmpty || diff.hunks[0].left.count > 0)
        // Every row outside the difference shows the same bytes on both sides.
        for index in 0..<layout.rowCount where layout.row(index).hunk == nil {
            let row = layout.row(index)
            #expect(a[row.left] == b[row.right])
        }
        #expect(layout.row(containing: 63, onLeft: true) == layout.row(containing: 83, onLeft: false))
    }

    @Test func `no bytes means no rows`() throws {
        #expect(HexLayout(diff: try compare([], []), bytesPerRow: 16).rowCount == 0)
    }
}

@Suite struct FileKindTests {
    private func kind(_ bytes: [UInt8], _ name: String) -> FileKind {
        FileKind.sniff(header: Data(bytes), fileName: name)
    }

    @Test func `text and tables are told apart by name`() {
        #expect(kind(Array("a,b\n1,2\n".utf8), "data.csv") == .table)
        #expect(kind(Array("a\tb\n".utf8), "data.TSV") == .table)
        #expect(kind(Array("a,b\n".utf8), "notes.txt") == .text)
    }

    @Test func `a nul byte means binary`() {
        #expect(kind([0x41, 0x00, 0x42], "file.bin") == .binary)
        #expect(kind([0x41, 0x00, 0x42], "data.csv") == .binary)
    }

    @Test func `images are recognized by their signature`() {
        #expect(kind([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0], "x") == .image)
        #expect(kind([0xFF, 0xD8, 0xFF, 0xE0], "photo.jpeg") == .image)
        #expect(kind(Array("GIF89a".utf8) + [0, 0], "a.gif") == .image)
        #expect(kind([0, 0, 0, 0x18] + Array("ftypheic".utf8), "a.heic") == .image)
        #expect(kind(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8), "a.webp") == .image)
        #expect(kind(Array("BMW is a car".utf8), "notes.txt") == .text)
    }

    @Test func `zip files are archives unless they are documents`() {
        let zip: [UInt8] = [0x50, 0x4B, 0x03, 0x04, 0x14, 0x00]
        #expect(kind(zip, "a.zip") == .archive(.zip))
        #expect(kind(zip, "a.jar") == .archive(.zip))
        #expect(kind(zip, "Letter.docx") == .document(.docx))
        #expect(kind(zip, "letter.odt") == .document(.odt))
        #expect(kind(zip, "sheet.xlsx") == .binary)
    }

    @Test func `compressed tarballs need their name`() {
        #expect(kind([0x1F, 0x8B, 0x08], "a.tar.gz") == .archive(.tarGzip))
        #expect(kind([0x1F, 0x8B, 0x08], "a.tgz") == .archive(.tarGzip))
        #expect(kind([0x1F, 0x8B, 0x08], "a.log.gz") == .binary)
        #expect(kind(Array("BZh9".utf8), "a.tar.bz2") == .archive(.tarBzip2))
        #expect(kind([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00], "a.txz") == .archive(.tarXz))
    }

    @Test func `a plain tar is found by its magic`() {
        var header = [UInt8](repeating: 0, count: 512)
        header.replaceSubrange(257..<262, with: Array("ustar".utf8))
        #expect(kind(header, "backup") == .archive(.tar))
    }

    @Test func `documents are recognized`() {
        #expect(kind(Array("%PDF-1.7\n".utf8), "a.pdf") == .document(.pdf))
        #expect(kind(Array("{\\rtf1\\ansi".utf8), "a.rtf") == .document(.rtf))
        #expect(kind([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1], "a.doc") == .document(.doc))
        #expect(kind([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1], "a.xls") == .binary)
    }
}
