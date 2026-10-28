import Foundation
@testable import Moire
import MoireKit
import Testing

/// Where files from Finder, the Dock or `open` go: never over a window that shows something.
@MainActor
struct WindowRoutingTests {
    private func file(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "moire-route-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func `files go to a new window when the front one has unsaved work`() async throws {
        let windows = Windows(observesFocus: false)
        let state = AppState()
        var opened: [WindowRequest] = []
        windows.register(state) { opened.append($0) }

        state.compare.load(try file("mine\n"), into: .left)
        for _ in 0..<200 where state.compare.left.url == nil { try await Task.sleep(for: .milliseconds(5)) }
        state.compare.setText("edited, not saved\n", on: .left)
        #expect(state.compare.hasUnsavedChanges)

        let incoming = [try file("a\n"), try file("b\n")]
        windows.open(incoming)
        #expect(opened.map(\.urls) == [incoming])
        // The window with the unsaved edit is untouched.
        #expect(state.compare.left.document.text == "edited, not saved\n")
        #expect(state.compare.hasUnsavedChanges)
    }

    @Test func `files go into the front window when it shows nothing yet`() async throws {
        let windows = Windows(observesFocus: false)
        let state = AppState()
        var opened: [WindowRequest] = []
        windows.register(state) { opened.append($0) }

        let incoming = [try file("a\n"), try file("b\n")]
        windows.open(incoming)
        #expect(opened.isEmpty)
        for _ in 0..<200 where state.compare.right.url == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(state.compare.left.url == incoming[0])
        #expect(state.compare.right.url == incoming[1])
    }

    @Test func `files that arrive before any window wait for the first one`() async throws {
        let windows = Windows(observesFocus: false)
        let incoming = [try file("a\n"), try file("b\n")]
        windows.open(incoming)

        let state = AppState()
        var opened: [WindowRequest] = []
        windows.register(state) { opened.append($0) }
        #expect(opened.isEmpty)
        for _ in 0..<200 where state.compare.right.url == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(state.compare.left.url == incoming[0])
    }

    @Test func `a window comparing server folders is not empty`() throws {
        let state = AppState()
        state.folders.set(try RemoteLocation.parse("sftp://example.com/srv").location, on: .left)
        #expect(!state.isEmpty)
    }
}

@MainActor
struct WaitingWorkTests {
    @Test func `waiting work gets exactly one window, however often it is asked`() {
        let windows = Windows(observesFocus: false)
        var opened = 0
        // The menus hand over the opener at launch; no window exists yet.
        windows.opener = { _ in opened += 1 }
        windows.withFrontmost { _ in }
        windows.openWindowForWaitingWork()
        windows.openWindowForWaitingWork()
        #expect(opened == 1)

        var ran = false
        windows.withFrontmost { _ in ran = true }
        windows.register(AppState()) { _ in opened += 1 }
        #expect(ran)
        // Nothing waits any more: no further windows.
        windows.openWindowForWaitingWork()
        #expect(opened == 1)
    }
}
