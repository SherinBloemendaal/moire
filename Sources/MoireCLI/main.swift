import Foundation
import MoireKit

// moire: compare files and folders from the command line or a script.
//
// Exit status follows diff(1): 0 when the sides are the same, 1 when they differ, 2 on trouble.

let usage = """
usage: moire compare LEFT RIGHT [options]
       moire sync LEFT RIGHT [--mode update|mirror] [--direction right|left|both] [--dry-run] [--yes] [options]

Compare two folders, or two files.

options:
  --method metadata|quick|binary|lines   how files are compared (default: binary, metadata on network disks)
  --include MASKS     only compare files matching these masks, e.g. "*.swift,*.md"
  --exclude MASKS     leave these out, e.g. "node_modules/,*.log"
  --gitignore         also leave out what .gitignore files ignore
  --hidden            include names that start with a dot
  --ignore-space      lines: ignore spaces at line ends (--ignore-all-space: all spaces)
  --ignore-case       lines: ignore upper and lower case
  --format text|json|html                folder report format (default: text)
  --differences       only list items that differ
  --output FILE       write the report to FILE instead of standard output
  --no-cache          read every file, even when an earlier run knows the answer

sync:
  --mode update       copy what is missing and replace older files (default)
  --mode mirror       make the target an exact copy; extra items go to the Trash
  --direction right   left to right (default), left: right to left, both: newer wins both ways
  --dry-run           only print the plan
  --yes               do not ask before syncing
"""

struct Failure: Error, CustomStringConvertible {
    let description: String
}

struct Arguments {
    var command = ""
    var paths: [String] = []
    var method: CompareMethod?
    var include: [String] = []
    var exclude: [String] = []
    var gitignore = false
    var hidden = false
    var whitespace = DiffOptions.Whitespace.exact
    var ignoreCase = false
    var format = FolderReport.Format.text
    var onlyDifferences = false
    var output: String?
    var useCache = true
    var mode = FolderSync.Mode.update
    var direction = FolderSync.Direction.leftToRight
    var dryRun = false
    var yes = false

    init(_ raw: [String]) throws {
        var rest = raw[...]
        guard let command = rest.popFirst() else { throw Failure(description: usage) }
        guard ["compare", "sync"].contains(command) else {
            throw Failure(description: command == "--help" || command == "-h" ? usage : "moire: unknown command \(command)\n\n\(usage)")
        }
        self.command = command
        func value(_ flag: String) throws -> String {
            guard let value = rest.popFirst() else { throw Failure(description: "moire: \(flag) needs a value") }
            return value
        }
        while let argument = rest.popFirst() {
            switch argument {
            case "--method":
                let name = try value(argument)
                guard let method = CompareMethod(rawValue: name) else { throw Failure(description: "moire: unknown method \(name)") }
                self.method = method
            case "--include": include += FolderFilter.patterns(from: try value(argument))
            case "--exclude": exclude += FolderFilter.patterns(from: try value(argument))
            case "--gitignore": gitignore = true
            case "--hidden": hidden = true
            case "--ignore-space": whitespace = .ignoreLeadingAndTrailing
            case "--ignore-all-space": whitespace = .ignoreAll
            case "--ignore-case": ignoreCase = true
            case "--format":
                let name = try value(argument)
                guard let format = FolderReport.Format(rawValue: name) else { throw Failure(description: "moire: unknown format \(name)") }
                self.format = format
            case "--differences": onlyDifferences = true
            case "--output": output = try value(argument)
            case "--no-cache": useCache = false
            case "--mode":
                let name = try value(argument)
                guard let mode = FolderSync.Mode(rawValue: name) else { throw Failure(description: "moire: unknown mode \(name)") }
                self.mode = mode
            case "--direction":
                switch try value(argument) {
                case "right": direction = .leftToRight
                case "left": direction = .rightToLeft
                case "both": direction = .both
                case let other: throw Failure(description: "moire: unknown direction \(other)")
                }
            case "--dry-run": dryRun = true
            case "--yes": yes = true
            case "--help", "-h": throw Failure(description: usage)
            default:
                guard !argument.hasPrefix("--") else { throw Failure(description: "moire: unknown option \(argument)") }
                paths.append(argument)
            }
        }
        guard paths.count == 2 else { throw Failure(description: "moire: \(command) needs exactly two paths\n\n\(usage)") }
    }
}

func url(_ path: String) -> URL {
    URL(filePath: path, relativeTo: URL.currentDirectory()).standardizedFileURL
}

func isFolder(_ url: URL) -> Bool? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else { return nil }
    return isDirectory.boolValue
}

func write(_ text: String, to output: String?) throws {
    guard let output else {
        FileHandle.standardOutput.write(Data(text.utf8))
        return
    }
    try Data(text.utf8).write(to: url(output))
}

func settings(_ arguments: Arguments, left: URL, right: URL) throws -> FolderCompareSettings {
    let method = try arguments.method ?? FolderCompareSettings.defaultMethod(
        left: Volume.of(left.path(percentEncoded: false)),
        right: Volume.of(right.path(percentEncoded: false))
    )
    return FolderCompareSettings(
        method: method,
        skipHidden: !arguments.hidden,
        diffOptions: DiffOptions(whitespace: arguments.whitespace, ignoreCase: arguments.ignoreCase),
        filter: FolderFilter(include: arguments.include, exclude: arguments.exclude, useGitignore: arguments.gitignore)
    )
}

func compareFolders(_ arguments: Arguments, left: URL, right: URL) throws -> FolderTree {
    let settings = try settings(arguments, left: left, right: right)
    let cache = arguments.useCache && settings.method != .metadata
        ? ResultCache(file: ResultCache.file(left: left, right: right, settings: settings))
        : nil
    let tree = try FolderEngine(left: left, right: right, settings: settings, cache: cache).run()
    do {
        try cache?.save()
    } catch {
        FileHandle.standardError.write(Data("moire: could not save the result cache: \(error.localizedDescription)\n".utf8))
    }
    return tree
}

func compareFiles(_ arguments: Arguments, left: URL, right: URL) throws -> Int32 {
    let a = try FileContent.read(left)
    let b = try FileContent.read(right)
    switch (a.body, b.body) {
    case let (.text(leftText, _), .text(rightText, _)):
        let diff = LineDiff(left: leftText, right: rightText, options: DiffOptions(whitespace: arguments.whitespace, ignoreCase: arguments.ignoreCase))
        let statistics = diff.statistics
        if statistics.isIdentical {
            try write("The files are the same.\n", to: arguments.output)
            return 0
        }
        try write("The files differ: \(statistics.added) added, \(statistics.removed) removed, \(statistics.changed) changed lines in \(diff.hunks.count) changes.\n", to: arguments.output)
        return 1
    default:
        let same = try Data(contentsOf: left) == Data(contentsOf: right)
        try write(same ? "The files are the same.\n" : "The files differ (compared byte for byte).\n", to: arguments.output)
        return same ? 0 : 1
    }
}

func describe(_ action: FolderSync.Action) -> String {
    switch action {
    case let .copy(path, toRight, bytes): "copy \(toRight ? "→" : "←") \(path) (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))"
    case let .createFolder(path, onRight): "new folder on the \(onRight ? "right" : "left"): \(path)/"
    case let .trash(path, onRight): "to the Trash from the \(onRight ? "right" : "left"): \(path)"
    }
}

func sync(_ arguments: Arguments, left: URL, right: URL) throws -> Int32 {
    let settings = try settings(arguments, left: left, right: right)
    let tree = try FolderEngine(left: left, right: right, settings: settings).run()
    let plan = FolderSync.plan(tree, mode: arguments.mode, direction: arguments.direction, settings: settings)
    guard !plan.actions.isEmpty else {
        print("Nothing to do.")
        return 0
    }
    for action in plan.actions { print(describe(action)) }
    print("\(plan.copies) to copy (\(ByteCountFormatter.string(fromByteCount: plan.bytesToCopy, countStyle: .file))), \(plan.trashes) to the Trash.")
    if arguments.dryRun { return 1 }

    if !arguments.yes {
        guard isatty(STDIN_FILENO) != 0 else { throw Failure(description: "moire: not syncing without --yes when there is no terminal to ask") }
        print("Sync now? [y/N] ", terminator: "")
        guard let answer = readLine(), answer.lowercased().hasPrefix("y") else {
            print("Nothing was changed.")
            return 1
        }
    }
    let failures = FolderSync.execute(plan, left: left, right: right)
    for failure in failures {
        FileHandle.standardError.write(Data("moire: \(failure.action.path): \(failure.message)\n".utf8))
    }
    print(failures.isEmpty ? "Done." : "Done, but \(failures.count) actions failed.")
    return failures.isEmpty ? 0 : 2
}

func main() -> Int32 {
    do {
        let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
        let left = url(arguments.paths[0])
        let right = url(arguments.paths[1])
        guard let leftIsFolder = isFolder(left) else { throw Failure(description: "moire: \(arguments.paths[0]) does not exist") }
        guard let rightIsFolder = isFolder(right) else { throw Failure(description: "moire: \(arguments.paths[1]) does not exist") }
        guard leftIsFolder == rightIsFolder else { throw Failure(description: "moire: compare two folders or two files, not one of each") }

        if arguments.command == "sync" {
            guard leftIsFolder else { throw Failure(description: "moire: sync works on folders") }
            return try sync(arguments, left: left, right: right)
        }
        guard leftIsFolder else { return try compareFiles(arguments, left: left, right: right) }

        let tree = try compareFolders(arguments, left: left, right: right)
        let options = FolderReport.Options(
            onlyDifferences: arguments.onlyDifferences,
            leftName: arguments.paths[0],
            rightName: arguments.paths[1],
            method: try settings(arguments, left: left, right: right).method
        )
        try write(FolderReport.render(tree, format: arguments.format, options: options), to: arguments.output)
        return tree.status(of: 0) == .identical ? 0 : 1
    } catch let failure as Failure {
        FileHandle.standardError.write(Data((failure.description + "\n").utf8))
        return 2
    } catch {
        FileHandle.standardError.write(Data("moire: \(error.localizedDescription)\n".utf8))
        return 2
    }
}

exit(main())
