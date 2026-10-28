import AppKit
import Foundation
@testable import Moire
import MoireKit
import SwiftUI
import Testing

/// The area of a button that takes a click is the frame it reports to accessibility: a chevron in
/// a borderless button reported 11 by 6 points, and a real click 5 points beside it did nothing.
@MainActor
enum ClickArea {
    static let minimum: CGFloat = 22

    static func text(_ element: NSObject, _ selector: Selector) -> String? {
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue() as? String
    }

    /// A button or checkbox, found by its label, title or help text.
    static func element(_ name: String, in host: NSView) -> NSObject? {
        let roles: Set<String> = [NSAccessibility.Role.button.rawValue, NSAccessibility.Role.checkBox.rawValue]
        return Press.elements(in: host).first { element in
            guard let role = text(element, #selector(NSAccessibilityProtocol.accessibilityRole)), roles.contains(role) else { return false }
            let texts: [Selector] = [
                #selector(NSAccessibilityProtocol.accessibilityLabel),
                #selector(NSAccessibilityProtocol.accessibilityTitle),
                #selector(NSAccessibilityProtocol.accessibilityHelp),
            ]
            return texts.contains { text(element, $0) == name }
        }
    }

    static func frame(of name: String, in host: NSView) -> NSRect? {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard let element = element(name, in: host), element.responds(to: selector) else { return nil }
        // The frame is a struct, which `perform` cannot return, so the method is called directly.
        typealias FrameMethod = @convention(c) (AnyObject, Selector) -> NSRect
        let frame = unsafeBitCast(element.method(for: selector), to: FrameMethod.self)(element, selector)
        return frame.width > 0 ? frame : nil
    }

    /// Waits for each named button and checks that it is at least `minimum` points each way.
    static func expectComfortable(_ names: [String], in host: NSView, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for name in names {
            try await Press.wait { frame(of: name, in: host) != nil }
            let frame = try #require(frame(of: name, in: host), "no button \(name)", sourceLocation: sourceLocation)
            #expect(frame.width >= minimum && frame.height >= minimum, "\(name) takes a click in \(frame.size) only", sourceLocation: sourceLocation)
        }
    }
}

@MainActor
@Suite(.serialized)
struct ClickAreaTests {
    private func folder(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "moire-click-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, text) in files { try Data(text.utf8).write(to: root.appending(path: name)) }
        return root
    }

    private func comparison() async throws -> CompareModel {
        let files = try folder(["a.txt": "one\ntwo\nthree\n", "b.txt": "one\nTWO\nthree\n"])
        let model = CompareModel()
        model.load(files.appending(path: "a.txt"), into: .left)
        model.load(files.appending(path: "b.txt"), into: .right)
        try await Press.wait { model.hunkCount > 0 && !model.isLoading }
        return model
    }

    /// The check itself: a bare chevron in a borderless button is as small as the glyph. If this
    /// ever reaches the minimum, the frames below say nothing about the click area.
    @Test func `a borderless chevron is smaller than the minimum`() async throws {
        let view = Button {} label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).help("Bare")
        let (window, host) = Press.host(view, size: NSSize(width: 200, height: 80))
        defer { window.orderOut(nil) }
        try await Press.wait { ClickArea.frame(of: "Bare", in: host) != nil }
        let frame = try #require(ClickArea.frame(of: "Bare", in: host))
        #expect(frame.width < ClickArea.minimum && frame.height < ClickArea.minimum)
    }

    @Test(arguments: ["glow", "glass"])
    func `the shared button styles take a click across the whole capsule`(style: String) async throws {
        let button = Button {} label: { Label("Styled", systemImage: "doc").padding(.horizontal, 6) }
        let view = Group {
            if style == "glow" { button.buttonStyle(GlowButtonStyle()) } else { button.buttonStyle(GlassButtonStyle()) }
        }
        let (window, host) = Press.host(view, size: NSSize(width: 300, height: 120))
        defer { window.orderOut(nil) }
        try await ClickArea.expectComfortable(["Styled"], in: host)
    }

    @Test func `the text comparison's bar buttons are comfortable to click`() async throws {
        let model = try await comparison()
        let (window, host) = Press.host(CompareView(model: model, compareFolders: {}), size: NSSize(width: 1000, height: 640))
        defer { window.orderOut(nil) }
        try await ClickArea.expectComfortable(["Go Up", "Go Down", "Skip Slide", "Swap the left and right side"], in: host)
    }

    @Test func `the find bar's buttons are comfortable to click`() async throws {
        let model = try await comparison()
        model.showSearch()
        model.searchQuery = "o"
        let (window, host) = Press.host(FindBar(model: model), size: NSSize(width: 700, height: 40))
        defer { window.orderOut(nil) }
        try await Press.wait { model.searchMatchCount > 0 }
        try await ClickArea.expectComfortable(["Aa", "Go Up", "Go Down", "Done"], in: host)
    }

    @Test func `the folder comparison's bar buttons are comfortable to click`() async throws {
        let model = FolderModel()
        model.pick(.binary)
        model.left = try folder(["a.txt": "a"])
        model.right = try folder(["a.txt": "b"])
        try await Press.wait { model.isComplete }
        let view = FolderView(model: model, openFiles: { _, _ in }, openDownloaded: { _, _ in })
        let (window, host) = Press.host(view, size: NSSize(width: 1100, height: 640))
        defer { window.orderOut(nil) }
        try await ClickArea.expectComfortable(["Filters", "Refresh", "Syncing", "Swap the left and right folder"], in: host)

        let generation = model.generation
        #expect(Press.press("Refresh", in: host))
        try await Press.wait { model.generation > generation }
        #expect(model.generation > generation)
    }

    @Test func `the merge's bar buttons are comfortable to click`() async throws {
        let files = try folder(["base.txt": "a\nb\nc\n", "left.txt": "a\nLEFT\nc\n", "right.txt": "a\nRIGHT\nc\n", "merged.txt": ""])
        let model = MergeModel()
        model.openMergetool(
            base: files.appending(path: "base.txt"), left: files.appending(path: "left.txt"),
            right: files.appending(path: "right.txt"), output: files.appending(path: "merged.txt")
        )
        try await Press.wait { model.merge != nil }
        let (window, host) = Press.host(MergeView(model: model), size: NSSize(width: 1240, height: 780))
        defer { window.orderOut(nil) }
        try await ClickArea.expectComfortable(["Go Up", "Go Down", "Skip Slide"], in: host)
    }

    @Test func `a bar toggle stays a checkbox and switches when pressed`() async throws {
        let model = try await comparison()
        let (window, host) = Press.host(CompareView(model: model, compareFolders: {}), size: NSSize(width: 1000, height: 640))
        defer { window.orderOut(nil) }
        try await Press.wait { ClickArea.element("Skip Slide", in: host) != nil }
        let toggle = try #require(ClickArea.element("Skip Slide", in: host))
        #expect(ClickArea.text(toggle, #selector(NSAccessibilityProtocol.accessibilityRole)) == NSAccessibility.Role.checkBox.rawValue)
        // Only Changes is remembered between launches, so the test starts from either value.
        let before = model.onlyChanges
        defer { model.onlyChanges = before }
        // While other suites run, the view can be rebuilt between finding the toggle and pressing
        // it, and a press on the old element is lost; it is found again and pressed once more.
        for _ in 0..<5 where model.onlyChanges == before {
            _ = ClickArea.element("Skip Slide", in: host)?.perform(#selector(NSAccessibilityProtocol.accessibilityPerformPress))
            try await Press.wait(1) { model.onlyChanges != before }
        }
        #expect(model.onlyChanges != before)
    }
}
