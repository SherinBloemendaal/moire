import Foundation
import MoireKit

/// Files Moire put in a temporary folder: copies downloaded from a server and unpacked archives.
/// They are removed again, so an edit saved into them would be lost: they open read-only, and the
/// recent comparisons do not remember them.
enum TemporaryCopies {
    static var folders: [URL] { [FolderModel.downloads, ArchiveExtractor.defaultParent] }

    static func contains(_ url: URL) -> Bool {
        contains(url, in: folders)
    }

    static func contains(_ path: String) -> Bool {
        contains(URL(filePath: path))
    }

    static func contains(_ url: URL, in folders: [URL]) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        return folders.contains { folder in
            var prefix = folder.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            if !prefix.hasSuffix("/") { prefix += "/" }
            return path.hasPrefix(prefix)
        }
    }
}
