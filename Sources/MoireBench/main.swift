import Foundation
import MoireKit

// moire-bench: builds fixed folder pairs and times the folder engine on them.
//
//   moire-bench run [--files 100000] [--large] [--repeat 3] [--root PATH]
//                   [--only PREFIX] [--json OUT] [--baseline FILE] [--max-regression 0.5]
//   moire-bench clean [--root PATH]
//
// Every scenario also checks the engine's answer against what the generator changed, so a fast
// but wrong engine fails instead of looking good.

struct Report: Codable {
    struct Scenario: Codable {
        var seconds: Double
        var runs: [Double]
        var files: Int
        var bytes: Int64
        var filesPerSecond: Double
        var megabytesPerSecond: Double
    }

    var machine: String
    var cores: Int
    var memoryGB: Int
    var date: String
    var scenarios: [String: Scenario]
}

struct Options {
    var command = "run"
    var files = 100_000
    var large = false
    var repeats = 3
    var root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "moire-bench")
    var json: URL?
    var baseline: URL?
    var maxRegression = 0.5
    /// Runs only the scenarios whose name starts with this.
    var only: String?

    init(_ arguments: [String]) throws {
        var arguments = arguments[...]
        if let first = arguments.first, !first.hasPrefix("--") {
            command = first
            arguments = arguments.dropFirst()
        }
        func value(_ flag: String) throws -> String {
            guard let value = arguments.popFirst() else { throw BenchError.usage("\(flag) needs a value") }
            return value
        }
        while let flag = arguments.popFirst() {
            switch flag {
            case "--files": files = try Int(value(flag)).orThrow(BenchError.usage("--files needs a number"))
            case "--large": large = true
            case "--repeat": repeats = try Int(value(flag)).orThrow(BenchError.usage("--repeat needs a number"))
            case "--root": root = URL(filePath: try value(flag))
            case "--json": json = URL(filePath: try value(flag))
            case "--baseline": baseline = URL(filePath: try value(flag))
            case "--only": only = try value(flag)
            case "--max-regression": maxRegression = try Double(value(flag)).orThrow(BenchError.usage("--max-regression needs a number"))
            default: throw BenchError.usage("unknown option \(flag)")
            }
        }
        guard repeats >= 1, files >= 200 else { throw BenchError.usage("--repeat must be at least 1 and --files at least 200") }
    }
}

enum BenchError: Error, CustomStringConvertible {
    case usage(String)
    case wrongAnswer(scenario: String, expected: Int, got: Int)
    case regression([String])

    var description: String {
        switch self {
        case .usage(let message): "usage: \(message)"
        case let .wrongAnswer(scenario, expected, got): "\(scenario): expected \(expected) differences, the engine found \(got)"
        case .regression(let lines): "slower than the baseline:\n" + lines.joined(separator: "\n")
        }
    }
}

extension Optional {
    func orThrow(_ error: Error) throws -> Wrapped {
        guard let self else { throw error }
        return self
    }
}

/// A named way of comparing a dataset, returning the number of files that differ.
struct Scenario {
    let name: String
    /// Datasets this scenario runs on; `nil` means all of them.
    var kinds: Set<String>? = nil
    /// The number of differences this way of comparing should find.
    var expected: (Dataset) throws -> Int = { $0.manifest.differences }
    let compare: (Dataset) throws -> Int
}

/// `MOIRE_FOLDER_THREADS` and `MOIRE_CONTENT_THREADS` override the thread counts, for tuning.
func engine(_ method: CompareMethod) -> (Dataset) throws -> Int {
    { dataset in
        let environment = ProcessInfo.processInfo.environment
        let settings = FolderCompareSettings(
            method: method,
            folderThreads: environment["MOIRE_FOLDER_THREADS"].flatMap(Int.init),
            contentThreads: environment["MOIRE_CONTENT_THREADS"].flatMap(Int.init)
        )
        return try FolderEngine(left: dataset.left, right: dataset.right, settings: settings).run().differenceCount
    }
}

/// Quick only looks at the first and last 64 KB, so it misses the one-letter change in the middle
/// of a file bigger than 128 KB. The tree generator makes a few of those.
func quickExpected(_ dataset: Dataset) throws -> Int {
    guard dataset.manifest.kind == "tree" else { return dataset.manifest.differences }
    var missed = 0
    for index in 0..<dataset.manifest.files where index % 200 != 17 && index % 100 == 7 {
        let path = dataset.left.appending(path: Dataset.path(index)).path(percentEncoded: false)
        let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int ?? 0
        if size > 2 * 64 * 1024 { missed += 1 }
    }
    return dataset.manifest.differences - missed
}

let scenarios: [Scenario] = [
    Scenario(name: "engine.metadata", compare: engine(.metadata)),
    Scenario(name: "engine.quick", expected: quickExpected, compare: engine(.quick)),
    Scenario(name: "engine.binary", compare: engine(.binary)),
    Scenario(name: "engine.lines", kinds: ["tree"], compare: engine(.lines)),
    // A second comparison of the same folders: the untimed first run fills the cache, every
    // timed run loads it, reads only what is not in it, and saves it again.
    Scenario(name: "engine.binary.cached", compare: { dataset in
        let cache = ResultCache(file: dataset.root.appending(path: "binary.cache"))
        let found = try FolderEngine(left: dataset.left, right: dataset.right, settings: FolderCompareSettings(method: .binary), cache: cache).run().differenceCount
        try cache.save()
        return found
    }),
]

func time(_ scenario: Scenario, on dataset: Dataset, repeats: Int) throws -> Report.Scenario {
    // One untimed run first, so every timed run starts with the same warm file cache.
    let found = try scenario.compare(dataset)
    let expected = try scenario.expected(dataset)
    guard found == expected else {
        throw BenchError.wrongAnswer(scenario: scenario.name, expected: expected, got: found)
    }
    var runs: [Double] = []
    for _ in 0..<repeats {
        let clock = ContinuousClock()
        let start = clock.now
        _ = try scenario.compare(dataset)
        let elapsed = clock.now - start
        runs.append(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }
    let median = runs.sorted()[runs.count / 2]
    return Report.Scenario(
        seconds: median,
        runs: runs,
        files: dataset.manifest.files,
        bytes: dataset.manifest.totalBytes,
        filesPerSecond: Double(dataset.manifest.files) / median,
        megabytesPerSecond: Double(dataset.manifest.totalBytes) / 1_048_576 / median
    )
}

func machineName() -> String {
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
    return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
}

/// Short scenarios vary by more than the allowed margin on their own: on GitHub's virtual runners
/// the same 0.1 s scenario measured anywhere from 0.06 s to 0.23 s. Only longer ones are gated.
let minimumGatedSeconds = 0.5
/// How many more times a scenario over the limit is timed before it counts as slower.
let retries = 2

@MainActor
func run(_ options: Options) throws {
    try FileManager.default.createDirectory(at: options.root, withIntermediateDirectories: true)
    var datasets: [(String, Dataset)] = []

    print("Preparing \(options.files) files in \(options.root.path(percentEncoded: false))…")
    datasets.append(("tree-\(options.files)", try Dataset.tree(files: options.files, in: options.root)))
    if options.large {
        print("Preparing 16 files of 64 MB…")
        datasets.append(("large-16x64mb", try Dataset.large(count: 16, megabytes: 64, in: options.root)))
    }

    var report = Report(
        machine: machineName(),
        cores: ProcessInfo.processInfo.activeProcessorCount,
        memoryGB: Int(ProcessInfo.processInfo.physicalMemory >> 30),
        date: ISO8601DateFormatter().string(from: Date()),
        scenarios: [:]
    )

    var timed: [String: (Scenario, Dataset)] = [:]
    for (datasetName, dataset) in datasets {
        for scenario in scenarios where options.only.map({ scenario.name.hasPrefix($0) }) ?? true {
            if let kinds = scenario.kinds, !kinds.contains(dataset.manifest.kind) { continue }
            let name = "\(scenario.name)/\(datasetName)"
            let result = try time(scenario, on: dataset, repeats: options.repeats)
            report.scenarios[name] = result
            timed[name] = (scenario, dataset)
            print(String(
                format: "%-36@ %8.3f s  %10.0f files/s  %8.1f MB/s",
                name as NSString, result.seconds, result.filesPerSecond, result.megabytesPerSecond
            ))
        }
    }

    if let tree = datasets.first.flatMap({ try? FolderEngine(left: $0.1.left, right: $0.1.right, settings: FolderCompareSettings(method: .metadata)).run() }) {
        print(String(format: "Folder tree storage: %.1f bytes per item (%d items)", Double(tree.storageBytes) / Double(tree.count), tree.count))
    }

    // GitHub's runners have slow stretches of several seconds, long enough to slow every run of
    // one scenario. A scenario over the limit is timed again, up to `retries` more times, and keeps
    // its fastest result: a real slowdown is slow every time, a slow stretch is not.
    var baseline: Report?
    if let baselineURL = options.baseline {
        let loaded = try JSONDecoder().decode(Report.self, from: Data(contentsOf: baselineURL))
        baseline = loaded
        for (name, base) in loaded.scenarios.sorted(by: { $0.key < $1.key }) where base.seconds >= minimumGatedSeconds {
            guard let entry = timed[name] else { continue }
            for attempt in 1...retries {
                guard let current = report.scenarios[name], current.seconds / base.seconds > 1 + options.maxRegression else { break }
                print(String(format: "%-36@ %8.3f s, over the limit: timing again (%d of %d)", name as NSString, current.seconds, attempt, retries))
                let again = try time(entry.0, on: entry.1, repeats: options.repeats)
                if again.seconds < current.seconds { report.scenarios[name] = again }
            }
        }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let json = options.json {
        try encoder.encode(report).write(to: json)
        print("Wrote \(json.path(percentEncoded: false))")
    }

    if let baseline {
        var slower: [String] = []
        for (name, base) in baseline.scenarios.sorted(by: { $0.key < $1.key }) where base.seconds >= minimumGatedSeconds {
            guard let current = report.scenarios[name] else { continue }
            let ratio = current.seconds / base.seconds
            print(String(format: "%-36@ %+6.0f%% against the baseline", name as NSString, (ratio - 1) * 100))
            if ratio > 1 + options.maxRegression {
                slower.append(String(format: "  %@: %.3f s, baseline %.3f s", name, current.seconds, base.seconds))
            }
        }
        if !slower.isEmpty { throw BenchError.regression(slower) }
    }
}

do {
    let options = try Options(Array(CommandLine.arguments.dropFirst()))
    switch options.command {
    case "run":
        try run(options)
    case "clean":
        try? FileManager.default.removeItem(at: options.root)
        print("Removed \(options.root.path(percentEncoded: false))")
    default:
        throw BenchError.usage("commands are run and clean")
    }
} catch {
    FileHandle.standardError.write(Data("moire-bench: \(error)\n".utf8))
    exit(1)
}
