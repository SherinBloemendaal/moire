import MoireKit
import SwiftUI

/// Shown for archives in the file comparison: they are compared as folders.
struct ArchiveCardView: View {
    let compare: CompareModel

    var body: some View {
        let files = compare.fileView
        KindLayout {
            VStack(spacing: 14) {
                Image(systemName: "archivebox").font(.system(size: 40)).foregroundStyle(Theme.brand)
                Text("Archives open like a folder").font(.title2.weight(.semibold))
                Text("Moire unpacks both archives into a temporary folder and compares what is inside, file by file. The unpacked files are removed again when you are done.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                if files.isOpeningArchives {
                    ProgressView("Unpacking…").controlSize(.small)
                } else {
                    Button {
                        files.openArchivesAsFolders?(compare.left.url, compare.right.url, false)
                    } label: {
                        Label("Compare as Folders", systemImage: "folder").padding(.horizontal, 6)
                    }
                    .buttonStyle(GlowButtonStyle())
                    .disabled(compare.left.url == nil && compare.right.url == nil)
                }
                Button("Show the Bytes Instead") { files.chosen = .hex }
                    .buttonStyle(.link)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } bar: {
            Spacer()
        }
        .onAppear { files.navigator = nil }
    }
}
