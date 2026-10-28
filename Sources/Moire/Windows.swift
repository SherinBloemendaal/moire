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
    static let log = Logger(subsystem: "io.github.sherinbloemendaal.moire", category: "windows")

    private struct Entry {
        weak var state: AppState?
        weak var window: NSWindow?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    /// Most recently focused first.
    private var order: [ObjectIdentifier] = []
    /// Opens a new window; SwiftUI's `openWindow` in the app, a recorder in tests.
    var opener: ((WindowRequest) -> Void)?
    /// Where a new tab goes: the window that was in front when it was asked for.
    private weak var tabParent: NSWindow?
    /// Work that arrived before any window existed (at launch): files to open, a merge to show.
    private var pending: [(AppState) -> Void] = []

    /// A stand-in for the menus while no window is open, so they show disabled instead of failing.
    let placeholder = AppState()

    /// `observesFocus` is off for windows made in tests, which have no key window to follow.
    init(observesFocus: Bool = true) {
        guard observesFocus else { return }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window, let state = Windows.shared.state(for: window) else { return }
                Windows.shared.focus(state)
                // SwiftUI may set its own delegate again; the guard goes back in front of it.
                CloseGuard.install(on: window, state: state)
            }
        }
    }

    private func state(for window: NSWindow) -> AppState? {
        entries.values.first { $0.window === window }?.state
    }

    var states: [AppState] { order.compactMap { entries[$0]?.state } }

    var frontmost: AppState? { states.first }

    /// The menus hand SwiftUI's `openWindow` over at launch, before any window exists.
    func provide(_ openWindow: OpenWindowAction) {
        guard opener == nil else { return }
        opener = { openWindow(value: $0) }
    }

    /// Launched to open files or a merge, macOS shows no window on its own (unless it restores
    /// some), so the work would wait forever. Shortly after launch, waiting work gets a window,
    /// which takes it over when it registers.
    func openWindowForWaitingWork() {
        guard frontmost == nil, !pending.isEmpty, !isOpeningForWaitingWork, let opener else { return }
        // Asked from more than one place at launch; the window takes a moment to register.
        isOpeningForWaitingWork = true
        opener(WindowRequest())
    }

    private var isOpeningForWaitingWork = false

    func register(_ state: AppState, openWindow: OpenWindowAction) {
        register(state) { openWindow(value: $0) }
    }

    func register(_ state: AppState, opener: @escaping (WindowRequest) -> Void) {
        self.opener = opener
        let key = ObjectIdentifier(state)
        if entries[key] == nil { entries[key] = Entry(state: state) }
        focus(state)
        let waiting = pending
        pending = []
        isOpeningForWaitingWork = false
        for action in waiting { action(state) }
    }

    func attach(_ window: NSWindow, to state: AppState, asTab: Bool) {
        // The window can show up before or after the view registers its comparison.
        entries[ObjectIdentifier(state), default: Entry(state: state)].window = window
        CloseGuard.install(on: window, state: state)
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
        if let opener {
            opener(WindowRequest(urls: urls))
        } else {
            withFrontmost { $0.open(urls) }
        }
    }

    /// `parent` is the key window; tests, which have none, pass their own.
    func newTab(beside parent: NSWindow? = NSApp.keyWindow) {
        tabParent = parent
        opener?(WindowRequest(asTab: true))
    }

    /// Files from Finder or the Dock: into the front window when it shows nothing yet, otherwise
    /// into a new window, so nothing on screen is replaced unasked.
    func open(_ urls: [URL]) {
        Self.log.info("Opening \(urls.count, privacy: .public) items from outside the app")
        guard let frontmost else {
            // At launch the first window may still be on its way; the files wait for it.
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

/// Asks about unsaved work before a window closes. SwiftUI keeps its own window delegate; this one
/// sits in front of it, answers `windowShouldClose(_:)` and passes everything else on.
final class CloseGuard: NSObject, NSWindowDelegate {
    /// Read from `responds(to:)`, which AppKit may call from any thread; set once, before use.
    nonisolated(unsafe) private weak var original: NSWindowDelegate?
    private weak var state: AppState?
    private static let log = Logger(subsystem: "io.github.sherinbloemendaal.moire", category: "windows")
    /// The window keeps its delegate weakly, so the guards are kept here.
    private static var guards: [ObjectIdentifier: CloseGuard] = [:]

    static func install(on window: NSWindow, state: AppState) {
        guard !(window.delegate is CloseGuard) else { return }
        let guardian = CloseGuard()
        guardian.original = window.delegate
        guardian.state = state
        guards[ObjectIdentifier(window)] = guardian
        window.delegate = guardian
        log.debug("Close guard in front of \(String(describing: guardian.original.map { type(of: $0) }), privacy: .public)")
    }

    /// Asks about unsaved work; replaced in tests, where an alert cannot be answered.
    static var confirm: (AppState) -> Bool = { AppDelegate.confirmQuit($0, closing: true) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let state, !Self.confirm(state) { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        original?.windowWillClose?(notification)
        if let window = notification.object as? NSWindow { Self.guards[ObjectIdentifier(window)] = nil }
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
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
                if let urls = request?.urls, !urls.isEmpty {
                    Windows.log.debug("New window opens \(urls.count, privacy: .public) items")
                    state.open(urls)
                }
            }
            .onDisappear { Windows.shared.unregister(state) }

    }
}

extension FocusedValues {
    @Entry var appState: AppState?
}
