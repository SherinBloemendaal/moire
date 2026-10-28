import AppKit
import MoireKit
import SwiftUI

/// What the user asked for from the folder list's menu or with a double-click.
enum FolderItemAction {
    case open(Int)
    case showInFinder([Int], SideID)
    case trash([Int], SideID)
    case rename(Int, SideID)
    case sync([Int])
}

/// The folder comparison as an AppKit outline view: only the visible rows exist, so a tree of
/// millions of items scrolls as smoothly as a small one.
struct FolderOutline: NSViewRepresentable {
    let tree: FolderTree
    let version: Int
    let differencesOnly: Bool
    /// Remote sides have no files here to show, rename, trash, sync or open.
    let leftIsLocal: Bool
    let rightIsLocal: Bool
    @Binding var selection: Set<Int>
    let perform: (FolderItemAction) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        outline.headerView = NSTableHeaderView()
        outline.usesAlternatingRowBackgroundColors = false
        outline.backgroundColor = .clear
        outline.style = .inset
        outline.rowSizeStyle = .custom
        outline.rowHeight = 24
        outline.allowsMultipleSelection = true
        outline.autoresizesOutlineColumn = false
        outline.indentationPerLevel = 16
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column == .name ? 160 : 60
            tableColumn.headerCell.alignment = column.alignment
            outline.addTableColumn(tableColumn)
            if column == .name { outline.outlineTableColumn = tableColumn }
        }

        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu
        context.coordinator.outline = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard coordinator.version != version || coordinator.differencesOnly != differencesOnly else { return }
        coordinator.version = version
        coordinator.differencesOnly = differencesOnly
        coordinator.tree = tree
        coordinator.children = [:]
        guard let outline = coordinator.outline else { return }

        let selected = selection
        coordinator.isUpdating = true
        outline.reloadData()
        let rows = IndexSet(selected.compactMap { coordinator.nodes[$0].map(outline.row(forItem:)) }.filter { $0 >= 0 })
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        coordinator.isUpdating = false
    }

    enum Column: String, CaseIterable {
        case name, leftSize, leftDate, rightSize, rightDate, status

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

        var title: String {
            switch self {
            case .name: "Name"
            case .leftSize: "Left Size"
            case .leftDate: "Left Modified"
            case .rightSize: "Right Size"
            case .rightDate: "Right Modified"
            case .status: "Status"
            }
        }

        var width: CGFloat {
            switch self {
            case .name: 320
            case .leftSize, .rightSize: 80
            case .leftDate, .rightDate: 140
            case .status: 110
            }
        }

        var alignment: NSTextAlignment {
            switch self {
            case .name: .left
            case .status: .center
            default: .right
            }
        }
    }

    /// A stable object per tree index: the outline view keeps expansion and selection by object,
    /// and indexes never change while a comparison grows.
    final class Node: NSObject {
        let index: Int
        init(_ index: Int) { self.index = index }
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: FolderOutline?
        weak var outline: NSOutlineView?
        var tree = FolderTree()
        var version = -1
        var differencesOnly = false
        var isUpdating = false
        var nodes: [Int: Node] = [:]
        /// The visible children per folder, for the current tree and filter.
        var children: [Int: [Int]] = [:]

        private let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter
        }()

        private func node(_ index: Int) -> Node {
            if let node = nodes[index] { return node }
            let node = Node(index)
            nodes[index] = node
            return node
        }

        private func visibleChildren(of index: Int) -> [Int] {
            if let cached = children[index] { return cached }
            guard index < tree.count else { return [] }
            let all = tree.children(of: index)
            let visible = differencesOnly ? all.filter { tree.status(of: $0) != .identical } : Array(all)
            children[index] = visible
            return visible
        }

        private func index(of item: Any?) -> Int {
            (item as? Node)?.index ?? 0
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            visibleChildren(of: index(of: item)).count
        }

        func outlineView(_ outlineView: NSOutlineView, child number: Int, ofItem item: Any?) -> Any {
            node(visibleChildren(of: index(of: item))[number])
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            let index = index(of: item)
            return tree.isDirectory(index) && !tree.children(of: index).isEmpty
        }

        // MARK: Cells

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let index = index(of: item)
            let cell = outlineView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? NSTableCellView ?? makeCell(column)
            let text = cell.textField
            text?.textColor = .labelColor
            text?.font = .systemFont(ofSize: 12)
            text?.layer?.backgroundColor = nil

            let left = tree.left(index)
            let right = tree.right(index)
            let status = tree.status(of: index)
            switch column {
            case .name:
                text?.stringValue = tree.name(of: index)
                text?.textColor = status == .identical ? .secondaryLabelColor : .labelColor
                let isFolder = left.kind == .directory || right.kind == .directory
                let symbol = isFolder ? "folder.fill" : (left.kind == .symbolicLink || right.kind == .symbolicLink ? "link" : "doc.text")
                cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                cell.imageView?.contentTintColor = isFolder ? NSColor(Theme.iris) : .secondaryLabelColor
            case .leftSize:
                text?.stringValue = size(left)
                text?.textColor = .secondaryLabelColor
            case .rightSize:
                text?.stringValue = size(right)
                text?.textColor = .secondaryLabelColor
            case .leftDate:
                text?.stringValue = date(left)
                text?.textColor = .secondaryLabelColor
            case .rightDate:
                text?.stringValue = date(right)
                text?.textColor = .secondaryLabelColor
            case .status:
                let (label, color) = Self.status(status, changedLines: tree.changedLines(of: index))
                text?.stringValue = label
                text?.textColor = NSColor(color)
                text?.font = .systemFont(ofSize: 10.5, weight: .semibold)
                text?.toolTip = tree.error(at: index)
            }
            return cell
        }

        private func makeCell(_ column: Column) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = column.identifier
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = column == .name ? .byTruncatingMiddle : .byTruncatingTail
            text.alignment = column.alignment
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            if column == .name {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                image.symbolConfiguration = .init(pointSize: 12, weight: .regular)
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 18),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                ])
            } else {
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4).isActive = true
            }
            NSLayoutConstraint.activate([
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func size(_ side: FolderTree.SideInfo) -> String {
            guard side.exists, side.kind != .directory else { return "" }
            return ByteCountFormatter.string(fromByteCount: side.size, countStyle: .file)
        }

        private func date(_ side: FolderTree.SideInfo) -> String {
            guard side.exists, side.kind != .directory else { return "" }
            return dateFormatter.string(from: Date(timeIntervalSince1970: Double(side.modified) / 1e9))
        }

        static func status(_ status: FolderTree.Status, changedLines: Int?) -> (String, Color) {
            switch status {
            case .identical: ("Identical", Theme.gutterText)
            case .different: (changedLines.map { $0 == 1 ? "1 line" : "\($0) lines" } ?? "Different", Theme.changed)
            case .leftOnly: ("Left only", Theme.removed)
            case .rightOnly: ("Right only", Theme.added)
            case .pending: ("Comparing…", Theme.iris)
            case .unreadable: ("Unreadable", Theme.removed)
            }
        }

        // MARK: Selection and actions

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let outline else { return }
            let selected = Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Node)?.index })
            parent?.selection = selected
        }

        @objc func doubleClicked(_ sender: NSOutlineView) {
            guard sender.clickedRow >= 0, let node = sender.item(atRow: sender.clickedRow) as? Node else { return }
            if tree.isDirectory(node.index) {
                if sender.isItemExpanded(node) { sender.collapseItem(node) } else { sender.expandItem(node) }
            } else {
                // The owner checks whether both files can be opened.
                parent?.perform(.open(node.index))
            }
        }

        /// The clicked row, or the selection when the click was inside it.
        private func targetItems() -> [Int] {
            guard let outline else { return [] }
            let clicked = outline.clickedRow
            if clicked >= 0, !outline.selectedRowIndexes.contains(clicked) {
                return (outline.item(atRow: clicked) as? Node).map { [$0.index] } ?? []
            }
            return outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Node)?.index }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let items = targetItems()
            guard !items.isEmpty else { return }

            func add(_ title: String, _ action: FolderItemAction, enabled: Bool = true) {
                let item = NSMenuItem(title: title, action: enabled ? #selector(runMenuItem(_:)) : nil, keyEquivalent: "")
                item.target = self
                item.representedObject = MenuAction(action)
                menu.addItem(item)
            }

            func isLocal(_ side: SideID) -> Bool {
                side == .left ? parent?.leftIsLocal ?? false : parent?.rightIsLocal ?? false
            }
            func exists(_ item: Int, _ side: SideID) -> Bool {
                side == .left ? tree.left(item).exists : tree.right(item).exists
            }

            if items.count == 1, !tree.isDirectory(items[0]) {
                let local = SideID.allCases.allSatisfy { !exists(items[0], $0) || isLocal($0) }
                add(local ? "Compare Files" : "Compare Files (downloads a read-only copy)", .open(items[0]))
                menu.addItem(.separator())
            }
            add("Sync…", .sync(items), enabled: isLocal(.left) && isLocal(.right))
            menu.addItem(.separator())
            for side in SideID.allCases {
                let available = isLocal(side) && items.contains { exists($0, side) }
                add("Show \(side.name) in Finder", .showInFinder(items, side), enabled: available)
            }
            menu.addItem(.separator())
            if items.count == 1 {
                for side in SideID.allCases {
                    add("Rename \(side.name)…", .rename(items[0], side), enabled: isLocal(side) && exists(items[0], side))
                }
            }
            for side in SideID.allCases {
                let available = isLocal(side) && items.contains { exists($0, side) }
                add("Move \(side.name) to Trash", .trash(items, side), enabled: available)
            }
        }

        @objc private func runMenuItem(_ sender: NSMenuItem) {
            guard let action = (sender.representedObject as? MenuAction)?.action else { return }
            parent?.perform(action)
        }

        private final class MenuAction: NSObject {
            let action: FolderItemAction
            init(_ action: FolderItemAction) { self.action = action }
        }
    }
}
