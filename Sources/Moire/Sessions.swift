import AppKit
import MoireKit
import SwiftUI
import UniformTypeIdentifiers

/// A comparison with its settings, as kept in the recent list and in `.moire` files.
struct ComparisonSession: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case text
        case folders
    }

    var kind: Kind
    var left: String?
    var right: String?
    // Folder settings.
    var method: String?
    var skipHidden: Bool?
    var include: String?
    var exclude: String?
    var useGitignore: Bool?
    // Text settings.
    var whitespace: String?
    var ignoreCase: Bool?

    var id: String { [kind.rawValue, left ?? "", right ?? ""].joined(separator: "\n") }

    /// "app ⇄ app-v2", for menus.
    var title: String {
        let names = [left, right].map { $0.map { ($0 as NSString).lastPathComponent } ?? "Untitled" }
        return names.joined(separator: " ⇄ ")
    }

    var subtitle: String {
        let parent = left.map { (($0 as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath } ?? ""
        return (kind == .folders ? "Folders" : "Files") + (parent.isEmpty ? "" : " · " + parent)
    }

    static let fileType = UTType(exportedAs: "io.github.sherinbloemendaal.moire.session", conformingTo: .json)
}

/// The last comparisons, newest first, kept in UserDefaults.
@Observable
final class RecentSessions {
    private(set) var sessions: [ComparisonSession] = []
    private let key = "recentSessions"
    private let limit = 15

    init() {
        if let data = UserDefaults.standard.data(forKey: key), let stored = try? JSONDecoder().decode([ComparisonSession].self, from: data) {
            sessions = stored
        }
    }

    func note(_ session: ComparisonSession) {
        guard session.left != nil, session.right != nil else { return }
        sessions.removeAll { $0.id == session.id }
        sessions.insert(session, at: 0)
        if sessions.count > limit { sessions.removeLast(sessions.count - limit) }
        save()
    }

    func clear() {
        sessions = []
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

extension AppState {
    /// What is on screen now, as a session.
    var currentSession: ComparisonSession? {
        switch mode {
        case .folders:
            guard folders.left != nil || folders.right != nil else { return nil }
            return ComparisonSession(
                kind: .folders,
                left: folders.left?.path(percentEncoded: false),
                right: folders.right?.path(percentEncoded: false),
                method: folders.method.rawValue,
                skipHidden: folders.skipHidden,
                include: folders.includeText,
                exclude: folders.excludeText,
                useGitignore: folders.useGitignore
            )
        case .merge:
            return nil
        case .text:
            guard compare.left.url != nil || compare.right.url != nil else { return nil }
            return ComparisonSession(
                kind: .text,
                left: compare.left.url?.path(percentEncoded: false),
                right: compare.right.url?.path(percentEncoded: false),
                whitespace: compare.options.whitespace.rawValue,
                ignoreCase: compare.options.ignoreCase
            )
        }
    }

    func restore(_ session: ComparisonSession) {
        let leftURL = session.left.map { URL(filePath: $0) }
        let rightURL = session.right.map { URL(filePath: $0) }
        let missing = [session.left, session.right].compactMap { $0 }.filter { !FileManager.default.fileExists(atPath: $0) }
        guard missing.isEmpty else {
            compare.errorMessage = "Not found any more: " + missing.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
            return
        }

        switch session.kind {
        case .folders:
            if let method = session.method.flatMap(CompareMethod.init(rawValue:)) { folders.preferredMethod = method }
            if let skipHidden = session.skipHidden { folders.skipHidden = skipHidden }
            if let include = session.include { folders.includeText = include }
            if let exclude = session.exclude { folders.excludeText = exclude }
            if let useGitignore = session.useGitignore { folders.useGitignore = useGitignore }
            folders.left = leftURL
            folders.right = rightURL
            mode = .folders
        case .text:
            var options = compare.options
            if let whitespace = session.whitespace.flatMap(DiffOptions.Whitespace.init(rawValue:)) { options.whitespace = whitespace }
            if let ignoreCase = session.ignoreCase { options.ignoreCase = ignoreCase }
            compare.options = options
            compare.openPair(left: leftURL, right: rightURL)
            mode = .text
        }
    }

    func saveSessionPanel() {
        guard let session = currentSession else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ComparisonSession.fileType]
        panel.nameFieldStringValue = session.title.replacingOccurrences(of: " ⇄ ", with: " vs ") + ".moire"
        panel.message = "Save this comparison with its settings, to open it again later."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(session).write(to: url, options: .atomic)
        } catch {
            compare.errorMessage = "Could not save the comparison: \(error.localizedDescription)"
        }
    }

    func openSession(_ url: URL) {
        do {
            restore(try JSONDecoder().decode(ComparisonSession.self, from: Data(contentsOf: url)))
        } catch {
            compare.errorMessage = "\(url.lastPathComponent) is not a Moire comparison: \(error.localizedDescription)"
        }
    }
}

struct RecentSessionsMenu: View {
    let state: AppState

    var body: some View {
        Menu("Open Recent Comparison") {
            ForEach(state.recents.sessions) { session in
                Button("\(session.title)  (\(session.subtitle))") { state.restore(session) }
            }
            if !state.recents.sessions.isEmpty {
                Divider()
                Button("Clear Menu") { state.recents.clear() }
            }
        }
        .disabled(state.recents.sessions.isEmpty)
    }
}
