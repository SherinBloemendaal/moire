import SwiftUI

struct ContentView: View {
    @Bindable var state: AppState

    var body: some View {
        Group {
            switch state.mode {
            case .text:
                CompareView(model: state.compare, compareFolders: { state.mode = .folders })
                    .transition(.opacity)
            case .folders:
                FolderView(model: state.folders) { left, right in
                    state.openFromFolders(left: left, right: right)
                }
                .transition(.opacity)
            case .merge:
                MergeView(model: state.merge)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: state.mode)
        .onChange(of: state.currentSession) { _, session in
            if let session { state.recents.note(session) }
        }
        .background(Theme.window)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if state.mode == .text, state.cameFromFolders {
                    Button { state.mode = .folders } label: {
                        Label("Folders", systemImage: "chevron.left")
                    }
                    .help("Back to the folder comparison")
                }
            }
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $state.mode) {
                    Label("Text", systemImage: "text.alignleft").tag(AppState.Mode.text)
                    Label("Folders", systemImage: "folder").tag(AppState.Mode.folders)
                    Label("Merge", systemImage: "arrow.triangle.merge").tag(AppState.Mode.merge)
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
                .fixedSize()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if state.mode == .text, !state.compare.isEmpty, !state.compare.isEditing {
                    ViewAsPicker(files: state.compare.fileView)
                }
                if state.mode == .text, !state.compare.isEmpty || state.compare.isEditing {
                    Toggle(isOn: Bindable(state.compare).isEditing) {
                        Label(state.compare.isEditing ? "Done" : "Edit", systemImage: state.compare.isEditing ? "checkmark" : "pencil")
                    }
                    .toggleStyle(.button)
                    .disabled(state.compare.hasBinarySide || !state.compare.fileView.allowsEditing)
                    .help(state.compare.isEditing ? "Show the differences (⌘E)" : "Edit both sides (⌘E)")
                }
            }
        }
        .toolbarBackground(Theme.window, for: .windowToolbar)
    }
}
