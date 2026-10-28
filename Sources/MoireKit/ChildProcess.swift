import Darwin
import Foundation
import Synchronization

/// A program started with pipes on its standard input, output and error, such as `ssh` or `curl`.
///
/// Started with `posix_spawn` instead of `Process`, so exactly the three pipes reach the child
/// (no other open files leak into it) and the parent owns its ends without guessing which ones
/// Foundation already closed.
final class ChildProcess: Sendable {
    let pid: pid_t
    /// The parent's ends. `input` is written to, `output` is read from; both are closed by the
    /// owner (`closeInput()`, `closeOutput()`) or when this object goes away.
    let input: Int32
    let output: Int32
    private let inputOpen = Atomic<Bool>(true)
    private let outputOpen = Atomic<Bool>(true)
    private let status = Mutex<Int32?>(nil)
    private let errors = ErrorBuffer()
    let executable: String

    init(executable: String, arguments: [String], environment: [String: String]? = nil) throws {
        self.executable = executable
        var inputPipe: [Int32] = [-1, -1]
        var outputPipe: [Int32] = [-1, -1]
        var errorPipe: [Int32] = [-1, -1]
        guard pipe(&inputPipe) == 0 else { throw POSIXError.current(path: executable) }
        guard pipe(&outputPipe) == 0 else {
            Self.closeAll(inputPipe)
            throw POSIXError.current(path: executable)
        }
        guard pipe(&errorPipe) == 0 else {
            Self.closeAll(inputPipe + outputPipe)
            throw POSIXError.current(path: executable)
        }
        for descriptor in [inputPipe[1], outputPipe[0], errorPipe[0]] {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        // Writing to a program that exited must give an error, not end this process.
        _ = fcntl(inputPipe[1], F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inputPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errorPipe[1], 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only 0, 1 and 2 stay open in the child.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF))
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGPIPE)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let environmentList: [UnsafeMutablePointer<CChar>?]? = environment.map { values in
            values.map { strdup("\($0.key)=\($0.value)") } + [nil]
        }
        defer { environmentList?.forEach { free($0) } }

        var child: pid_t = 0
        let result = if let environmentList {
            posix_spawn(&child, executable, &actions, &attributes, argv, environmentList)
        } else {
            posix_spawn(&child, executable, &actions, &attributes, argv, environ)
        }
        Self.closeAll([inputPipe[0], outputPipe[1], errorPipe[1]])
        guard result == 0 else {
            Self.closeAll([inputPipe[1], outputPipe[0], errorPipe[0]])
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO, userInfo: [NSFilePathErrorKey: executable])
        }
        pid = child
        input = inputPipe[1]
        output = outputPipe[0]

        let errorDescriptor = errorPipe[0]
        let thread = Thread { [errors] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(errorDescriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                // Error text is short; a program that floods it is cut off rather than kept.
                errors.text.withLock { if $0.count < 64 * 1024 { $0.append(contentsOf: buffer[0..<count]) } }
            }
            Darwin.close(errorDescriptor)
            errors.done.signal()
        }
        thread.name = "Moire \((executable as NSString).lastPathComponent) errors"
        thread.start()
    }

    deinit {
        closeInput()
        closeOutput()
        if status.withLock({ $0 }) == nil {
            kill(pid, SIGTERM)
            let pid = pid
            // Reaped on a thread of its own so the program does not stay behind as a zombie.
            Thread.detachNewThread {
                var result: Int32 = 0
                while waitpid(pid, &result, 0) < 0, errno == EINTR {}
            }
        }
    }

    private final class ErrorBuffer: Sendable {
        let text = Mutex(Data())
        let done = DispatchSemaphore(value: 0)
    }

    private static func closeAll(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 { close(descriptor) }
    }

    func closeInput() {
        if inputOpen.exchange(false, ordering: .acquiringAndReleasing) { close(input) }
    }

    func closeOutput() {
        if outputOpen.exchange(false, ordering: .acquiringAndReleasing) { close(output) }
    }

    func terminate() {
        if status.withLock({ $0 }) == nil { kill(pid, SIGTERM) }
    }

    /// Writes all of `data` to the program's input.
    func write(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(input, base + written, buffer.count - written)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPIPE)
                }
                written += result
            }
        }
    }

    /// Reads up to `count` bytes of output; 0 at the end.
    func read(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        while true {
            let result = Darwin.read(output, buffer, count)
            if result >= 0 { return result }
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Reads exactly `count` bytes; `false` when the output ended first.
    func readExactly(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Bool {
        var total = 0
        while total < count {
            let result = try read(into: buffer + total, count: count - total)
            if result == 0 { return false }
            total += result
        }
        return true
    }

    /// Everything left on the output.
    func readToEnd() throws -> Data {
        var data = Data()
        let chunk = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let count = try read(into: buffer, count: chunk)
            if count == 0 { return data }
            data.append(buffer.assumingMemoryBound(to: UInt8.self), count: count)
        }
    }

    /// Waits for the program to end and returns its exit code, or 128 plus the signal that ended it.
    @discardableResult
    func wait() -> Int32 {
        status.withLock { status in
            if let status { return status }
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) < 0 {
                guard errno == EINTR else {
                    status = -1
                    return -1
                }
            }
            let signal = raw & 0x7f
            let code = signal == 0 ? (raw >> 8) & 0xff : 128 + signal
            status = code
            return code
        }
    }

    /// What the program wrote to its standard error. Waits a moment for the rest of it, but not
    /// forever: a helper the program left running (an ssh master connection) can keep it open.
    func errorOutput() -> String {
        if errors.done.wait(timeout: .now() + 2) == .success { errors.done.signal() }
        return String(decoding: errors.text.withLock { $0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
