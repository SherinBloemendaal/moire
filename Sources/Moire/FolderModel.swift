import AppKit
import MoireKit
import SwiftUI

@Observable
final class FolderModel {
    enum Filter: String, CaseIterable {
        case all
        case differences
    }

    var left: URL? { didSet { compareIfReady() } }
    var right: URL? { didSet { compareIfReady() } }
    var skipHidden = UserDefaults.standard.object(forKey: "skipHidden") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(skipHidden, forKey: "skipHidden")
            compareIfReady()
        }
    }
    var filter = Filter.all
    var collapsed: Set<String> = []
    var selection: Set<String> = []

    private(set) var comparison: FolderComparison?
    private(set) var isComparing = false
    var errorMessage: String?
    private var task: Task<Void, Never>?

    var visibleItems: [FolderComparison.Item] {
        guard let comparison else { return [] }
        return comparison.items.filter { item in
            if filter == .differences, item.status == .identical { return false }
            return !collapsed.contains { item.path.hasPrefix($0 + "/") }
        }
    }

    func count(_ status: FolderComparison.Status) -> Int {
        comparison?.items.count { !$0.isDirectory && $0.status == status } ?? 0
    }

    func choose(_ side: SideID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Choose the \(side.name.lowercased()) folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        set(url, on: side)
    }

    func set(_ url: URL, on side: SideID) {
        if side == .left { left = url } else { right = url }
    }

    /// Takes dropped folders: two fill both sides, one fills the first empty side.
    func open(_ urls: [URL]) {
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        if folders.count >= 2 {
            left = folders[0]
            right = folders[1]
        } else if let folder = folders.first {
            set(folder, on: left == nil ? .left : (right == nil ? .right : .left))
        }
    }

    func swapSides() {
        let previous = left
        left = right
        right = previous
    }

    func refresh() { compareIfReady() }

    func toggle(_ item: FolderComparison.Item) {
        guard item.isDirectory else { return }
        if collapsed.contains(item.path) { collapsed.remove(item.path) } else { collapsed.insert(item.path) }
    }

    private func compareIfReady() {
        task?.cancel()
        guard let left, let right else {
            comparison = nil
            return
        }
        let options = FolderComparison.Options(skipHidden: skipHidden)
        isComparing = true
        task = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try FolderComparison(left: left, right: right, options: options) }
            }.value
            guard !Task.isCancelled else { return }
            isComparing = false
            switch result {
            case .success(let comparison):
                self.comparison = comparison
                collapsed = collapsed.filter { path in comparison.items.contains { $0.path == path } }
            case .failure(let error):
                comparison = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}
