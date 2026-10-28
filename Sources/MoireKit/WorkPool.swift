import Foundation

/// A fixed set of OS threads working through a shared stack of jobs. Jobs may add more jobs.
///
/// Folder reads and file reads block in system calls, so they run on threads of their own
/// rather than on Swift's cooperative pool, which has one thread per core and stalls when those
/// threads wait for a disk.
final class WorkPool<Job: Sendable>: @unchecked Sendable {
    // Every mutable field below is only touched while `condition` is locked.
    private let condition = NSCondition()
    private var jobs: [Job] = []
    private var active = 0
    private var isCancelled = false
    private var isClosed = false
    private let work: @Sendable (Job) -> Void

    init(threads: Int, name: String, work: @escaping @Sendable (Job) -> Void) {
        self.work = work
        for index in 0..<max(1, threads) {
            let thread = Thread { [self] in loop() }
            thread.name = "\(name) \(index + 1)"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    func submit(_ newJobs: [Job]) {
        guard !newJobs.isEmpty else { return }
        condition.lock()
        if !isCancelled { jobs.append(contentsOf: newJobs) }
        condition.broadcast()
        condition.unlock()
    }

    /// Blocks until every job, including jobs added by jobs, has finished or the pool was cancelled.
    func waitUntilIdle() {
        condition.lock()
        while !(jobs.isEmpty && active == 0) {
            condition.wait()
        }
        condition.unlock()
    }

    /// Drops the jobs that have not started. Running jobs finish their current step.
    func cancel() {
        condition.lock()
        isCancelled = true
        jobs.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    var cancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isCancelled
    }

    /// Lets the threads end once the work is done. Call after `waitUntilIdle()`.
    func close() {
        condition.lock()
        isClosed = true
        condition.broadcast()
        condition.unlock()
    }

    private func loop() {
        while true {
            condition.lock()
            while jobs.isEmpty && !isClosed {
                condition.wait()
            }
            guard let job = jobs.popLast() else {
                condition.unlock()
                return
            }
            active += 1
            condition.unlock()

            work(job)

            condition.lock()
            active -= 1
            if jobs.isEmpty && active == 0 { condition.broadcast() }
            condition.unlock()
        }
    }
}
