import Foundation
import MoireKit

/// Unpacks archives so the folder comparison can show what is inside them, and removes the
/// unpacked files once their folder is no longer compared.
@Observable
final class ArchiveRouter {
    private(set) var isUnpacking = false
    /// Archive names being unpacked, for a progress message.
    private(set) var unpacking: [String] = []
    @ObservationIgnored private var extracted: [ExtractedArchive] = []
    /// The router of every window, to name files of archives any of them unpacked.
    private static let routers = NSHashTable<ArchiveRouter>.weakObjects()

    init() {
        Self.routers.add(self)
    }
    @ObservationIgnored private var task: Task<Void, Never>?

    enum RouteError: LocalizedError {
        case notAnArchive(String)

        var errorDescription: String? {
            switch self {
            case .notAnArchive(let name): "\(name) is not an archive Moire can open, nor a folder."
            }
        }
    }

    /// The archive a folder of the folder comparison was unpacked from, so it can be shown by
    /// that name instead of its temporary path.
    func archive(for folder: URL?) -> URL? {
        guard let folder else { return nil }
        return extracted.first { $0.folder == folder }?.archive
    }

    /// Where a file of an unpacked archive came from, e.g. `~/Downloads/app.zip/src`, to show
    /// instead of its temporary folder. Nil for a file that is not in one.
    static func origin(of url: URL) -> String? {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        for extracted in routers.allObjects.flatMap(\.extracted) {
            var prefix = extracted.folder.standardizedFileURL.path(percentEncoded: false)
            if !prefix.hasSuffix("/") { prefix += "/" }
            guard path.hasPrefix(prefix) else { continue }
            let parent = (String(path.dropFirst(prefix.count)) as NSString).deletingLastPathComponent
            let name = (extracted.archive.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
            return parent.isEmpty ? name : name + "/" + parent
        }
        return nil
    }

    /// Whether a URL is something this router opens: an archive, as opposed to a folder or file.
    static func isArchive(_ url: URL) -> Bool {
        guard !isFolder(url), case .archive = FileKind.detect(url) else { return false }
        return true
    }

    static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Unpacks the archives among `left` and `right` (folders are used as they are), then calls
    /// `done` with the folders to compare. A side that is nil stays as it is.
    func open(left: URL?, right: URL?, failed: @escaping (String) -> Void, done: @escaping (URL?, URL?) -> Void) {
        task?.cancel()
        unpacking = [left, right].compactMap { $0 }.filter(Self.isArchive).map(\.lastPathComponent)
        isUnpacking = true
        task = Task {
            defer {
                isUnpacking = false
                unpacking = []
            }
            do {
                async let leftFolder = Self.resolve(left)
                async let rightFolder = Self.resolve(right)
                let (l, r) = try await (leftFolder, rightFolder)
                guard !Task.isCancelled else { return }
                extracted.append(contentsOf: [l?.archive, r?.archive].compactMap { $0 })
                done(l?.folder, r?.folder)
            } catch is CancellationError {
                return
            } catch {
                failed(error.localizedDescription)
            }
        }
    }

    /// Removes unpacked archives whose folder is not one of `inUse`.
    func release(keeping inUse: [URL?]) {
        extracted.removeAll { archive in
            guard !inUse.contains(archive.folder) else { return false }
            archive.remove()
            return true
        }
    }

    func removeAll() {
        task?.cancel()
        extracted.forEach { $0.remove() }
        extracted = []
    }

    private static func resolve(_ url: URL?) async throws -> (folder: URL, archive: ExtractedArchive?)? {
        guard let url else { return nil }
        if isFolder(url) { return (url, nil) }
        guard case .archive(let format) = FileKind.detect(url) else {
            throw RouteError.notAnArchive(url.lastPathComponent)
        }
        let archive = try await ArchiveExtractor.extract(url, format: format)
        return (archive.folder, archive)
    }
}
