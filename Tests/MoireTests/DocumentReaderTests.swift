import AppKit
import CoreText
@testable import Moire
import MoireKit
import PDFKit
import Testing

/// Reads documents made at test time through the same path the document comparison uses.
struct DocumentReaderTests {
    private func file(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "moire-document-\(UUID().uuidString).\(ext)")
    }

    /// A PDF with one page per string, drawn as real text so PDFKit can take it out again.
    private func pdf(_ pages: [String]) throws -> URL {
        let url = file("pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for page in pages {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: page, attributes: [.font: font]))
            context.textPosition = CGPoint(x: 72, y: 760)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    @Test func `takes the text out of every page of a PDF`() throws {
        let url = try pdf(["Hello from page one", "Second page here"])
        let extracted = try DocumentReader.read(url, format: .pdf)
        #expect(extracted.pageCount == 2)
        #expect(Array(extracted.document.lines) == [
            DocumentText.pageMarker(1), "Hello from page one", DocumentText.pageMarker(2), "Second page here",
        ])
    }

    @Test func `refuses a PDF locked with a password`() throws {
        let url = try pdf(["Secret"])
        let document = try #require(PDFDocument(url: url))
        let locked = file("pdf")
        #expect(document.write(to: locked, withOptions: [.userPasswordOption: "user", .ownerPasswordOption: "owner"]))
        #expect {
            try DocumentReader.read(locked, format: .pdf)
        } throws: { error in
            guard case .locked = error as? DocumentReader.ReadError else { return false }
            return true
        }
    }

    @Test func `takes the paragraphs out of a Word document`() throws {
        let text = NSAttributedString(string: "First paragraph\nSecond paragraph\n\n\nAfter a gap")
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        let url = file("docx")
        try data.write(to: url)

        let extracted = try DocumentReader.read(url, format: .docx)
        #expect(extracted.pageCount == nil)
        #expect(Array(extracted.document.lines) == ["First paragraph", "Second paragraph", "", "After a gap"])
    }

    @Test func `reports a file that is not the document it claims to be`() throws {
        for format in [DocumentFormat.pdf, .docx] {
            let url = file(format.rawValue)
            try Data("not a document".utf8).write(to: url)
            #expect {
                try DocumentReader.read(url, format: format)
            } throws: { error in
                guard case .unreadable = error as? DocumentReader.ReadError else { return false }
                return true
            }
        }
    }
}
