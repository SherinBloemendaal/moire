import MoireKit
import SwiftUI

/// Finds text in both documents. Return goes to the next match, Shift-Return to the previous
/// one, Escape closes the bar.
struct FindBar: View {
    @Bindable var model: CompareModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in both sides", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { model.findPrevious() } else { model.findNext() }
                    return .handled
                }
                .onExitCommand { model.hideSearch() }

            Toggle(isOn: $model.searchCaseSensitive) {
                Text("Aa").font(.system(size: 11, weight: .semibold))
            }
            .toggleStyle(.bar)
            .help(model.searchCaseSensitive ? "Upper and lower case must match" : "Upper and lower case are the same")

            Text(status)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(model.searchMatchCount == 0 && !model.searchQuery.isEmpty && !model.isSearching ? Theme.removed : .secondary)
                .frame(minWidth: 80, alignment: .trailing)

            HStack(spacing: 2) {
                Button { model.findPrevious() } label: { Image(systemName: "chevron.up") }
                    .help("Previous match (⇧⌘G)")
                Button { model.findNext() } label: { Image(systemName: "chevron.down") }
                    .help("Next match (⌘G)")
            }
            .buttonStyle(.bar)
            .disabled(model.searchMatchCount == 0)

            Button("Done") { model.hideSearch() }
                .buttonStyle(.bar)
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassBar()
        .onAppear { isFocused = true }
        .onChange(of: model.searchFocusRequest) { isFocused = true }
    }

    private var status: String {
        if model.searchQuery.isEmpty { return "" }
        if model.isSearching, model.searchResults == nil { return "Searching…" }
        let count = model.searchMatchCount
        if count == 0 { return "No matches" }
        if let current = model.currentMatch { return "\((current + 1).formatted()) of \(count.formatted())" }
        return count == 1 ? "1 match" : "\(count.formatted()) matches"
    }
}

/// Jumps to a line number on one side.
struct GoToLineView: View {
    @Bindable var model: CompareModel
    @State private var text = ""
    @AppStorage("goToLineSide") private var sideName = "left"
    @Environment(\.dismiss) private var dismiss

    private var side: SideID { sideName == "right" ? .right : .left }

    private var lineCount: Int {
        guard let diff = model.diff else { return 0 }
        return side == .left ? diff.left.lines.count : diff.right.lines.count
    }

    private var number: Int? {
        Int(text.trimmingCharacters(in: .whitespaces)).flatMap { (1...max(lineCount, 1)).contains($0) ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Go to Line").font(.headline)
            Picker("Side", selection: $sideName) {
                Text("Left").tag("left")
                Text("Right").tag("right")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("Line number, 1 to \(lineCount.formatted())", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(go)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Go", action: go)
                    .keyboardShortcut(.defaultAction)
                    .disabled(number == nil)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    private func go() {
        guard let number else { return }
        model.goToLine(number, on: side)
        dismiss()
    }
}
