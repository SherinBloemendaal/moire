import Foundation

/// Reads FTP folder listings: `MLSD` (RFC 3659), which every modern server has, and the older
/// `LIST`, whose format is not standard but nearly always Unix `ls -l` or the DOS style of IIS.
enum FTPListing {
    struct Item: Hashable {
        var entry: DirectoryEntry
        /// Where a symbolic link points, when the listing says.
        var linkTarget: String?
    }

    static func lines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    // MARK: MLSD

    /// One `type=file;size=12;modify=20240105143000; name` line per item.
    static func mlsd(_ data: Data) -> [Item] {
        lines(data).compactMap(mlsdLine)
    }

    static func mlsdLine(_ line: String) -> Item? {
        // The facts end with "; " and the name, which may hold spaces itself, is the rest. Some
        // servers leave out the last semicolon; then the first space ends the facts.
        let space: String.Index
        if let end = line.range(of: "; ") {
            space = line.index(before: end.upperBound)
        } else if let first = line.firstIndex(of: " ") {
            space = first
        } else {
            return nil
        }
        let name = String(line[line.index(after: space)...])
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
        var facts: [String: String] = [:]
        for fact in line[..<space].split(separator: ";") {
            guard let equals = fact.firstIndex(of: "=") else { continue }
            facts[fact[..<equals].lowercased()] = String(fact[fact.index(after: equals)...])
        }
        let type = facts["type"]?.lowercased() ?? ""
        var kind: DirectoryEntry.Kind
        var target: String?
        switch type {
        case "file":
            kind = .file
        case "dir":
            kind = .directory
        case "cdir", "pdir":
            return nil
        default:
            // Unix servers mark links as `OS.unix=slink:target` or `OS.unix=symlink`.
            if type.hasPrefix("os.unix=slink") || type.hasPrefix("os.unix=symlink") {
                kind = .symbolicLink
                let raw = facts["type"] ?? ""
                if let colon = raw.firstIndex(of: ":") { target = String(raw[raw.index(after: colon)...]) }
            } else {
                kind = .other
            }
        }
        let size = kind == .file ? Int64(facts["size"] ?? "") ?? 0 : 0
        let modified = facts["modify"].flatMap(RemoteDate.mlsd) ?? 0
        return Item(entry: DirectoryEntry(name: name, kind: kind, size: size, modified: modified, fileID: 0), linkTarget: target)
    }

    // MARK: LIST

    /// Unix `ls -l` lines and DOS lines; anything else (a `total 12` line) is skipped. Dates are
    /// taken as UTC: LIST does not say which time zone the server uses.
    static func list(_ data: Data, now: Date = Date()) -> [Item] {
        lines(data).compactMap { unixLine($0, now: now) ?? dosLine($0) }
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// The words of a line with where each starts, so a name with runs of spaces stays whole.
    private static func words(_ line: String) -> [(word: Substring, start: String.Index)] {
        var result: [(Substring, String.Index)] = []
        var index = line.startIndex
        while index < line.endIndex {
            while index < line.endIndex, line[index] == " " || line[index] == "\t" { index = line.index(after: index) }
            guard index < line.endIndex else { break }
            let start = index
            while index < line.endIndex, line[index] != " ", line[index] != "\t" { index = line.index(after: index) }
            result.append((line[start..<index], start))
        }
        return result
    }

    /// `drwxr-xr-x  2 owner group  4096 Mar  5 14:02 name`, with or without the group, and
    /// `name -> target` for links.
    static func unixLine(_ line: String, now: Date) -> Item? {
        guard let first = line.first, "-dlbcps".contains(first) else { return nil }
        let words = words(line)
        guard words.count >= 6, words[0].word.count >= 10 else { return nil }
        // The date is the month word followed by a day and a time or year.
        guard let monthIndex = (2..<(words.count - 2)).first(where: { index in
            months.contains(words[index].word.lowercased()) && Int(words[index + 1].word) != nil && index + 3 < words.count
        }) else { return nil }
        guard let month = months.firstIndex(of: words[monthIndex].word.lowercased()).map({ $0 + 1 }),
              let day = Int(words[monthIndex + 1].word)
        else { return nil }
        let size = Int64(words[monthIndex - 1].word) ?? 0
        let timeOrYear = words[monthIndex + 2].word

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        var modified: Int64?
        if timeOrYear.contains(":") {
            let parts = timeOrYear.split(separator: ":")
            guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
            // No year means within the last six months: this year, or last year for a date that
            // would otherwise lie in the future.
            let year = calendar.component(.year, from: now)
            modified = RemoteDate.nanoseconds(year: year, month: month, day: day, hour: hour, minute: minute)
            if let date = modified, date > Int64(now.timeIntervalSince1970 + 86_400) * 1_000_000_000 {
                modified = RemoteDate.nanoseconds(year: year - 1, month: month, day: day, hour: hour, minute: minute)
            }
        } else if let year = Int(timeOrYear) {
            modified = RemoteDate.nanoseconds(year: year, month: month, day: day)
        }
        guard let modified else { return nil }

        var name = String(line[words[monthIndex + 3].start...])
        var target: String?
        let kind: DirectoryEntry.Kind
        switch first {
        case "-": kind = .file
        case "d": kind = .directory
        case "l":
            kind = .symbolicLink
            if let arrow = name.range(of: " -> ") {
                target = String(name[arrow.upperBound...])
                name = String(name[..<arrow.lowerBound])
            }
        default: kind = .other
        }
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
        return Item(entry: DirectoryEntry(name: name, kind: kind, size: kind == .file ? size : 0, modified: modified, fileID: 0), linkTarget: target)
    }

    /// `01-05-24  02:30PM       <DIR>          name` or `... 1234 name`, as IIS lists.
    static func dosLine(_ line: String) -> Item? {
        let words = words(line)
        guard words.count >= 4 else { return nil }
        let dateParts = words[0].word.split(separator: "-")
        guard dateParts.count == 3, let month = Int(dateParts[0]), let day = Int(dateParts[1]), var year = Int(dateParts[2]) else { return nil }
        if year < 100 { year += year < 70 ? 2000 : 1900 }
        let time = words[1].word.uppercased()
        let isPM = time.hasSuffix("PM")
        let clock = time.replacingOccurrences(of: "AM", with: "").replacingOccurrences(of: "PM", with: "").split(separator: ":")
        guard clock.count == 2, var hour = Int(clock[0]), let minute = Int(clock[1]) else { return nil }
        if time.hasSuffix("AM") || isPM {
            if hour == 12 { hour = 0 }
            if isPM { hour += 12 }
        }
        guard let modified = RemoteDate.nanoseconds(year: year, month: month, day: day, hour: hour, minute: minute) else { return nil }
        let name = String(line[words[3].start...])
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
        if words[2].word.uppercased() == "<DIR>" {
            return Item(entry: DirectoryEntry(name: name, kind: .directory, size: 0, modified: modified, fileID: 0))
        }
        guard let size = Int64(words[2].word) else { return nil }
        return Item(entry: DirectoryEntry(name: name, kind: .file, size: size, modified: modified, fileID: 0))
    }
}
