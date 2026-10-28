import MoireKit
import SwiftUI

/// Shows the pair in the view that fits it (or the one picked by hand), in place of the text
/// comparison and its status bar.
struct FileKindView: View {
    @Bindable var model: CompareModel

    var body: some View {
        switch model.fileView.current {
        case .text: EmptyView()
        case .hex: HexCompareView(compare: model)
        case .image: ImageCompareView(compare: model)
        case .table: TableCompareView(compare: model)
        case .document: DocumentCompareView(compare: model)
        case .archive: ArchiveCardView(compare: model)
        }
    }
}

/// The pane and the bar below it, laid out like the text comparison.
struct KindLayout<Content: View, Bar: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var bar: Bar

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.pane)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.paneBorder))
                .padding(.horizontal, 14)
            HStack(spacing: 8) { bar }
                .font(.system(size: 12))
                .controlSize(.small)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
        }
    }
}

/// "3 of 12" with buttons for the previous and next difference.
struct DifferenceStepper: View {
    var count: Int
    var current: Int?
    var noun = "differences"
    var previous: () -> Void
    var next: () -> Void

    var body: some View {
        if count > 0 {
            HStack(spacing: 2) {
                Button(action: previous) { Image(systemName: "chevron.up") }
                    .help("Previous difference (⌥⌘↑)")
                Text(current.map { "\($0 + 1) of \(count)" } ?? "\(count) \(noun)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .frame(minWidth: 70)
                Button(action: next) { Image(systemName: "chevron.down") }
                    .help("Next difference (⌥⌘↓)")
            }
            .buttonStyle(.bar)
        }
    }
}

/// A centered icon, title and line of text, for empty, waiting and failed states.
struct KindMessage: View {
    var systemImage: String
    var title: String
    var message: String?
    var isWorking = false

    var body: some View {
        VStack(spacing: 12) {
            if isWorking {
                ProgressView().controlSize(.regular)
            } else {
                Image(systemName: systemImage).font(.system(size: 38)).foregroundStyle(Theme.brand)
            }
            Text(title).font(.title3.weight(.semibold))
            if let message {
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The toolbar menu that switches between text, hex, image, table and document text.
struct ViewAsPicker: View {
    @Bindable var files: FileViewModel

    var body: some View {
        Menu {
            Picker("View As", selection: Binding(get: { files.current }, set: { files.chosen = $0 })) {
                ForEach(files.available) { view in
                    Label(view.title + (view == files.automatic ? " (Automatic)" : ""), systemImage: view.systemImage).tag(view)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(files.current.title, systemImage: files.current.systemImage)
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help("Show the files as text, hex, an image, a table or document text")
    }
}

/// Runs work off the main thread, and cancels it when the calling task is cancelled.
func runDetached<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
    let task = Task.detached(priority: .userInitiated, operation: work)
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

extension Int64 {
    var fileSizeText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension Int {
    var fileSizeText: String { Int64(self).fileSizeText }
}
