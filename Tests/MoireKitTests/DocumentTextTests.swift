@testable import MoireKit
import Testing

@Suite struct DocumentTextTests {
    @Test func `pages are joined with a marker before each`() {
        let document = DocumentText.pages(["First page\nline two", "Second page"])
        #expect(document.lines == ["--- Page 1 ---", "First page", "line two", "--- Page 2 ---", "Second page"])
    }

    @Test func `an empty page still gets its marker`() {
        #expect(DocumentText.pages(["", "x"]).lines == ["--- Page 1 ---", "--- Page 2 ---", "x"])
    }

    @Test func `layout characters become plain text`() {
        let text = "one\u{2029}two\u{2028}three\u{0C}four co\u{AD}operate\u{A0}x\u{FFFC}"
        #expect(DocumentText.normalize(text) == "one\ntwo\nthree\nfour cooperate x")
    }

    @Test func `spaces at line ends and extra empty lines go`() {
        #expect(DocumentText.normalize("a  \n\n\n\nb\t\n\n") == "a\n\nb")
        #expect(DocumentText.normalize("\n\nstart") == "start")
    }

    @Test func `line breaks of every kind are the same`() {
        #expect(DocumentText.text("a\r\nb\rc\n").lines == ["a", "b", "c"])
    }
}
