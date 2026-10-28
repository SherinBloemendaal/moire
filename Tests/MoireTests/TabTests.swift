import AppKit
import Foundation
@testable import Moire
import Testing

/// New Tab joins the window that was in front instead of opening beside it.
@MainActor
@Suite(.serialized)
struct TabTests {
    /// Never closed: closing the last window would end the test process. Ordered out instead.
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func `new tab asks for a tab and joins the front window`() {
        let windows = Windows(observesFocus: false)
        let front = window()
        front.orderFront(nil)
        defer { front.orderOut(nil) }
        var opened: [WindowRequest] = []
        windows.register(AppState()) { opened.append($0) }

        windows.newTab(beside: front)
        #expect(opened.map(\.asTab) == [true])

        let tab = window()
        defer { tab.orderOut(nil) }
        windows.attach(tab, to: AppState(), asTab: opened[0].asTab)
        #expect(front.tabbedWindows?.contains { $0 === tab } == true)
        #expect(tab.tabGroup === front.tabGroup)
        #expect(tab.tabbingMode == .preferred)
    }

    @Test func `a new window opens on its own, also right after a tab was asked for`() {
        let windows = Windows(observesFocus: false)
        let front = window()
        front.orderFront(nil)
        defer { front.orderOut(nil) }
        var opened: [WindowRequest] = []
        windows.register(AppState()) { opened.append($0) }

        windows.newWindow()
        #expect(opened.map(\.asTab) == [false])
        let separate = window()
        defer { separate.orderOut(nil) }
        windows.attach(separate, to: AppState(), asTab: false)
        #expect(front.tabbedWindows?.contains { $0 === separate } != true)

        // A tab joins the window it was asked from once, not every window shown after it.
        windows.newTab(beside: front)
        let tab = window()
        defer { tab.orderOut(nil) }
        windows.attach(tab, to: AppState(), asTab: true)
        let later = window()
        defer { later.orderOut(nil) }
        windows.attach(later, to: AppState(), asTab: true)
        #expect(front.tabbedWindows?.contains { $0 === tab } == true)
        #expect(front.tabbedWindows?.contains { $0 === later } != true)
    }

    @Test func `a tab asked for without a front window opens as a window`() {
        let windows = Windows(observesFocus: false)
        var opened: [WindowRequest] = []
        windows.register(AppState()) { opened.append($0) }
        let hidden = window()

        windows.newTab(beside: hidden)
        let tab = window()
        defer { tab.orderOut(nil) }
        windows.attach(tab, to: AppState(), asTab: true)
        #expect(hidden.tabbedWindows?.contains { $0 === tab } != true)
        #expect(tab.tabbedWindows == nil || tab.tabbedWindows?.count == 1)
    }
}
