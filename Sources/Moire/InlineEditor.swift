import AppKit
import MoireKit

/// A one-line text view laid over a line of the comparison. Typing changes that line of the
/// document; Return, joining lines and pasting several lines change the lines around it, and
/// the arrow keys move it to the line above or below.
final class InlineEditor: NSObject, NSTextViewDelegate {
    let side: SideID
    var line: Int
    let scrollView = EditorScrollView()
    let textView: NSTextView
    weak var controller: DiffListController?
    /// True while the text is set from the document, so that is not taken for typing.
    private var isLoading = false

    init(side: SideID, line: Int, metrics: DiffMetrics, controller: DiffListController) {
        self.side = side
        self.line = line
        self.controller = controller
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: metrics.lineHeight))
        super.init()

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: metrics.textInset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = false
        textView.minSize = NSSize(width: 0, height: metrics.lineHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: metrics.lineHeight)
        textView.font = metrics.font
        textView.textColor = Palette.text
        textView.defaultParagraphStyle = metrics.paragraph
        textView.typingAttributes = [.font: metrics.font, .foregroundColor: Palette.text, .paragraphStyle: metrics.paragraph]
        textView.insertionPointColor = Palette.iris
        textView.delegate = self

        scrollView.documentView = textView
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
    }

    var text: String { textView.string }

    func load(_ text: String, caret: Int?) {
        isLoading = true
        textView.string = text
        textView.setSelectedRange(NSRange(location: min(caret ?? 0, (text as NSString).length), length: 0))
        isLoading = false
    }

    /// Lines the text up with the drawn text of the other lines.
    func scroll(toOffset offset: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: max(0, min(offset, textView.frame.width - scrollView.bounds.width)), y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func textDidChange(_ notification: Notification) {
        guard !isLoading else { return }
        controller?.editorDidChange(self)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let controller else { return false }
        let selection = textView.selectedRange()
        let length = (textView.string as NSString).length
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            controller.editorInsert(self, text: "\n")
            return true
        case #selector(NSResponder.deleteBackward(_:)) where selection == NSRange(location: 0, length: 0):
            return controller.editorJoin(self, withNext: false)
        case #selector(NSResponder.deleteForward(_:)) where selection.length == 0 && selection.location == length:
            return controller.editorJoin(self, withNext: true)
        case #selector(NSResponder.moveUp(_:)):
            return controller.editorMove(self, by: -1)
        case #selector(NSResponder.moveDown(_:)):
            return controller.editorMove(self, by: 1)
        case #selector(NSResponder.cancelOperation(_:)):
            controller.endEditing()
            return true
        default:
            return false
        }
    }

    /// Text with a line break in it, pasted or dropped, becomes several lines.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard !isLoading, let replacement = replacementString, replacement.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else { return true }
        controller?.editorInsert(self, text: replacement, replacing: range)
        return false
    }
}

/// Hands scrolling to the comparison: the line itself only scrolls to follow the caret.
final class EditorScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        superview?.scrollWheel(with: event)
    }
}
