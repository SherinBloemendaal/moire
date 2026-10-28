@testable import MoireKit
import Testing

@Suite struct CSVTests {
    @Test func `plain fields and rows`() {
        #expect(CSV.parse("a,b,c\n1,2,3\n").rows == [["a", "b", "c"], ["1", "2", "3"]])
    }

    @Test func `the last row needs no line break`() {
        #expect(CSV.parse("a,b\n1,2").rows == [["a", "b"], ["1", "2"]])
    }

    @Test func `quoted fields hold delimiters, quotes and line breaks`() {
        let text = "name,note\n\"Smith, J.\",\"said \"\"hi\"\"\"\n\"two\nlines\",x\n"
        #expect(CSV.parse(text).rows == [["name", "note"], ["Smith, J.", "said \"hi\""], ["two\nlines", "x"]])
    }

    @Test func `CRLF and CR end rows, and CRLF inside quotes is kept`() {
        #expect(CSV.parse("a,b\r\n1,2\r\n").rows == [["a", "b"], ["1", "2"]])
        #expect(CSV.parse("a,b\r1,2\r").rows == [["a", "b"], ["1", "2"]])
        #expect(CSV.parse("\"x\r\ny\",z\r\n").rows == [["x\r\ny", "z"]])
    }

    @Test func `empty fields are kept`() {
        #expect(CSV.parse("a,,c\n,\n\"\",x\n").rows == [["a", "", "c"], ["", ""], ["", "x"]])
        #expect(CSV.parse("a,").rows == [["a", ""]])
    }

    @Test func `empty lines are skipped`() {
        #expect(CSV.parse("a,b\n\n1,2\n\n").rows == [["a", "b"], ["1", "2"]])
        #expect(CSV.parse("").rows.isEmpty)
    }

    @Test func `stray quotes are kept the way spreadsheets do`() {
        #expect(CSV.parse("ab\"c,d\n").rows == [["ab\"c", "d"]])
        #expect(CSV.parse("\"ab\"c,d\n").rows == [["abc", "d"]])
        #expect(CSV.parse("\"open,d\n").rows == [["open,d\n"]])
    }

    @Test func `the delimiter is detected`() {
        #expect(CSV.detectDelimiter("a;b;c\n1;2;3\n") == ";")
        #expect(CSV.detectDelimiter("a\tb\n1\t2\n") == "\t")
        #expect(CSV.detectDelimiter("a,b\n1,2\n") == ",")
        // Commas inside the fields do not count.
        #expect(CSV.detectDelimiter("\"1,5\";\"2,5\"\n\"3,5\";\"4\"\n") == ";")
        #expect(CSV.detectDelimiter("just one column\nsecond\n") == ",")
        #expect(CSV.parse("x;y\n1;2\n").rows == [["x", "y"], ["1", "2"]])
    }

    @Test func `a chosen delimiter wins over detection`() {
        #expect(CSV.parse("a;b,c\n", delimiter: ",").rows == [["a;b", "c"]])
    }
}

@Suite struct TableDiffTests {
    private func table(_ text: String) -> CSVTable { CSV.parse(text, delimiter: ",") }

    @Test func `identical tables`() {
        let diff = TableDiff(left: table("id,name\n1,a\n2,b\n"), right: table("id,name\n1,a\n2,b\n"))
        #expect(diff.statistics.isIdentical)
        #expect(diff.rows.allSatisfy { $0.kind == .same })
        #expect(diff.rows.count == 2)
    }

    @Test func `changed cells are counted per column`() {
        let diff = TableDiff(left: table("id,name,city\n1,a,x\n2,b,y\n"), right: table("id,name,city\n1,a,z\n2,c,w\n"))
        #expect(diff.statistics.changed == 2)
        #expect(diff.statistics.changedCells == 3)
        #expect(diff.rows[0].changedColumns == [2])
        #expect(diff.rows[1].changedColumns == [1, 2])
    }

    @Test func `without keys rows are lined up like lines`() {
        let diff = TableDiff(left: table("id,name\n1,a\n2,b\n3,c\n"), right: table("id,name\n1,a\n3,c\n4,d\n"))
        #expect(diff.rows.map(\.kind) == [.same, .removed, .same, .added])
        #expect(diff.statistics.added == 1)
        #expect(diff.statistics.removed == 1)
        // A removed and an added row in the same place are one changed row.
        let edited = TableDiff(left: table("id,name\n1,a\n2,b\n3,c\n"), right: table("id,name\n1,a\n2,x\n3,c\n"))
        #expect(edited.rows.map(\.kind) == [.same, .changed, .same])
        #expect(edited.rows[1].changedColumns == [1])
    }

    @Test func `with a key sorting does not matter`() {
        let left = table("id,name\n1,a\n2,b\n3,c\n")
        let right = table("id,name\n3,c\n1,a\n2,changed\n4,new\n")
        let diff = TableDiff(left: left, right: right, keyColumns: [0])
        #expect(diff.keyColumns == [0])
        #expect(diff.statistics.changed == 1)
        #expect(diff.statistics.added == 1)
        #expect(diff.statistics.removed == 0)
        let changed = diff.rows.first { $0.kind == .changed }
        #expect(changed?.left == 2)
        #expect(changed?.right == 3)
    }

    @Test func `rows only the left has keep their place`() {
        let diff = TableDiff(left: table("id\n1\n2\n3\n"), right: table("id\n1\n3\n"), keyColumns: [0])
        #expect(diff.rows.map(\.kind) == [.same, .removed, .same])
        #expect(diff.rows[1].left == 2)
    }

    @Test func `duplicate keys are matched in order and reported`() {
        let diff = TableDiff(left: table("id,v\n1,a\n1,b\n"), right: table("id,v\n1,a\n1,c\n"), keyColumns: [0])
        #expect(diff.duplicateKeys == 2)
        #expect(diff.rows.map(\.kind) == [.same, .changed])
    }

    @Test func `columns are matched by name when they move or are added`() {
        let left = table("id,name,city\n1,a,x\n")
        let right = table("city,id,name,zip\nx,1,a,9999\n")
        let diff = TableDiff(left: left, right: right)
        #expect(diff.columns.map(\.name).sorted() == ["city", "id", "name", "zip"])
        #expect(diff.columns.filter(\.isShared).count == 3)
        #expect(diff.statistics.addedColumns == 1)
        #expect(diff.statistics.changed == 0)
        #expect(diff.rows.map(\.kind) == [.same])
    }

    @Test func `without a header columns are matched by position`() {
        let diff = TableDiff(left: table("1,a\n"), right: table("1,b,extra\n"), hasHeader: false)
        #expect(diff.columns.map(\.name) == ["A", "B", "C"])
        #expect(diff.rows.first?.changedColumns == [1])
        #expect(diff.statistics.addedColumns == 1)
    }

    @Test func `the ignore options apply to cells`() {
        let options = DiffOptions(whitespace: .ignoreLeadingAndTrailing, ignoreCase: true)
        let diff = TableDiff(left: table("k\n Apple \n"), right: table("k\napple\n"), options: options)
        #expect(diff.statistics.isIdentical)
    }

    @Test func `short rows read as empty cells`() {
        let diff = TableDiff(left: table("a,b\n1\n"), right: table("a,b\n1,\n"))
        #expect(diff.statistics.isIdentical)
    }

    @Test func `column letters`() {
        #expect(TableDiff.letters(0) == "A")
        #expect(TableDiff.letters(25) == "Z")
        #expect(TableDiff.letters(26) == "AA")
        #expect(TableDiff.letters(701) == "ZZ")
        #expect(TableDiff.letters(702) == "AAA")
    }
}
