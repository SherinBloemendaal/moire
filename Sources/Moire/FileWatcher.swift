import Foundation

/// What a file on disk looks like right now: a change of any of it means it was written.
nonisolated struct FileSignature: Equatable, Sendable {
    var inode: UInt64
    var size: Int64
    var modified: timespec

    init?(url: URL) {
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0 else { return nil }
        inode = info.st_ino
        size = info.st_size
        modified = info.st_mtimespec
    }

    static func == (lhs: FileSignature, rhs: FileSignature) -> Bool {
        lhs.inode == rhs.inode && lhs.size == rhs.size
            && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
    }
}

/// Calls `onChange` shortly after a file was written. Editors that save by writing a new file
/// and moving it over the old one are followed to the new file; while the file is gone, its
/// folder is watched until it is back.
final class FileWatcher {
    let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        watchFile()
    }

    func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    private func watchFile() {
        let descriptor = open(url.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else {
            watchFolder()
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke, .attrib, .link],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.fileEvent(source.data) }
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    private func fileEvent(_ events: DispatchSource.FileSystemEvent) {
        if !events.isDisjoint(with: [.delete, .rename, .revoke]) {
            // The file this source follows is gone or moved; follow the path instead.
            source?.cancel()
            source = nil
            watchFile()
        }
        scheduleChange()
    }

    private func watchFolder() {
        let folder = url.deletingLastPathComponent()
        let descriptor = open(folder.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .link], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.folderEvent() }
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    private func folderEvent() {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        source?.cancel()
        source = nil
        watchFile()
        scheduleChange()
    }

    /// Several events come for one save; they become one call.
    private func scheduleChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.onChange() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}
