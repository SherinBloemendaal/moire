import AppKit
import os
import SwiftUI

/// What a new window should show. Each window (or tab) has its own comparison.
struct WindowRequest: Codable, Hashable {
    var id = UUID()
    var urls: [URL] = []
    /// Join the window that was in front as a tab, instead of opening beside it.
    var asTab = false
}

/// Keeps track of the open windows, so the menus, Finder and the command line reach the right one.
@Observable
final class Windows {
    static let shared = Windows()
    private static let log = Logger(subsystem: "io.github.sherinbloemendaal.moire", category: "windows")

    private struct Entry {
        weak var state: AppState?
        weak var window: NSWindow?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    /// Most recently focused first.
    private var order: [ObjectIdentifier] = []
    private var openWindow: OpenWindowAction?
    /// Where a new tab goes: the window that was in front when it was asked for.
    private weak var tabParent: NSWindow?
    /// Files that arrived before any window existed (at launch).
    private var pending: [(AppState) -> Void] = []

    /// A stand-in for the menus while no window is open, so they show disabled instead of failing.
    let placeholder = AppState()

    private init() {
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window, let state = Windows.shared.state(for: window) else { return }
                Windows.shared.focus(state)
            }
        }
    }

    private func state(for window: NSWindow) -> AppState? {
        entries.values.first { $0.window === window }?.state
    }

    var states: [AppState] { order.compactMap { entries[$0]?.state } }

    var frontmost: AppState? { states.first }

    func register(_ state: AppState, openWindow: OpenWindowAction) {
        self.openWindow = openWindow
        let key = ObjectIdentifier(state)
        if entries[key] == nil { entries[key] = Entry(state: state) }
        focus(state)
        let waiting = pending
        pending = []
        for action in waiting { action(state) }
    }

    func attach(_ window: NSWindow, to state: AppState, asTab: Bool) {
        // The window can show up before or after the view registers its comparison.
        entries[ObjectIdentifier(state), default: Entry(state: state)].window = window
        window.tabbingMode = .preferred
        if asTab, let parent = tabParent, parent !== window, parent.isVisible {
            parent.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }
        tabParent = nil
    }

    func focus(_ state: AppState) {
        let key = ObjectIdentifier(state)
        order.removeAll { $0 == key }
        order.insert(key, at: 0)
    }

    func unregister(_ state: AppState) {
        let key = ObjectIdentifier(state)
        entries[key] = nil
        order.removeAll { $0 == key }
    }

    /// Runs `action` on the front window, or on the first window once it exists.
    func withFrontmost(_ action: @escaping (AppState) -> Void) {
        if let frontmost { action(frontmost) } else { pending.append(action) }
    }

    func newWindow(urls: [URL] = []) {
        if let openWindow {
            openWindow(value: WindowRequest(urls: urls))
        } else {
            withFrontmost { $0.open(urls) }
        }
    }

    func newTab() {
        tabParent = NSApp.keyWindow
        openWindow?(value: WindowRequest(asTab: true))
    }

    /// Files from Finder or the Dock: into the front window when it shows nothing yet, otherwise
    /// into a new window, so nothing on screen is replaced unasked.
    func open(_ urls: [URL]) {
        Self.log.info("Opening \(urls.count, privacy: .public) items from outside the app")
        guard let frontmost else {
            // At launch the first window is still on its way; the files wait for it.
            pending.append { $0.open(urls) }
            return
        }
        if frontmost.isEmpty {
            frontmost.open(urls)
        } else {
            newWindow(urls: urls)
        }
    }
}

/// Hands the hosting `NSWindow` to a closure once the view is in a window.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// One window: its own comparison, registered so menus and Finder can reach it.
struct WindowRoot: View {
    let request: WindowRequest?
    @State private var state = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(state: state)
            .frame(minWidth: 820, minHeight: 520)
            .navigationTitle(state.windowTitle)
            .focusedSceneValue(\.appState, state)
            .background(WindowReader { window in
                Windows.shared.attach(window, to: state, asTab: request?.asTab == true)
            })
            .onAppear {
                Windows.shared.register(state, openWindow: openWindow)
                if let urls = request?.urls, !urls.isEmpty { state.open(urls) }
            }
            .onDisappear { Windows.shared.unregister(state) }

    }
}

extension FocusedValues {
    @Entry var appState: AppState?
}
