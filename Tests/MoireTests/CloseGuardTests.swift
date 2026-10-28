import AppKit
import Foundation
@testable import Moire
import Testing

/// Stands in for SwiftUI's own window delegate.
private final class RecordingDelegate: NSObject, NSWindowDelegate {
    var asked = 0
    var resized = 0
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        asked += 1
        return true
    }
    func windowDidResize(_ notification: Notification) { resized += 1 }
}

@MainActor
@Suite(.serialized)
struct CloseGuardTests {
    private func window(with delegate: RecordingDelegate, state: AppState) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        CloseGuard.install(on: window, state: state)
        return window
    }

    @Test func `keeps the window open when the user cancels`() {
        let delegate = RecordingDelegate()
        let state = AppState()
        let window = window(with: delegate, state: state)
        defer { CloseGuard.confirm = { AppDelegate.confirmQuit($0, closing: true) } }

        var askedAbout: AppState?
        CloseGuard.confirm = { askedAbout = $0; return false }
        window.orderFrontRegardless()
        window.performClose(nil)
        #expect(window.isVisible)
        #expect(askedAbout === state)
        // SwiftUI's delegate is not asked when the user already said no.
        #expect(delegate.asked == 0)

        CloseGuard.confirm = { _ in true }
        window.performClose(nil)
        #expect(!window.isVisible)
        #expect(delegate.asked == 1)
    }

    @Test func `passes every other delegate call on to SwiftUI's delegate`() {
        let delegate = RecordingDelegate()
        let window = window(with: delegate, state: AppState())
        #expect(window.delegate is CloseGuard)
        window.setContentSize(NSSize(width: 400, height: 300))
        #expect(delegate.resized == 1)
    }

    @Test func `installs once per window`() {
        let delegate = RecordingDelegate()
        let state = AppState()
        let window = window(with: delegate, state: state)
        let first = window.delegate
        CloseGuard.install(on: window, state: state)
        #expect(window.delegate === first)
    }
}
