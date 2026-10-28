import Darwin
import Foundation

/// Dates as servers write them, read without formatters (which are slow and not thread safe).
enum RemoteDate {
    /// Nanoseconds since 1970 for a UTC date and time; `nil` when a part is out of range.
    static func nanoseconds(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0, nanosecond: Int64 = 0) -> Int64? {
        guard (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else { return nil }
        var parts = tm()
        parts.tm_year = Int32(year - 1900)
        parts.tm_mon = Int32(month - 1)
        parts.tm_mday = Int32(day)
        parts.tm_hour = Int32(hour)
        parts.tm_min = Int32(minute)
        parts.tm_sec = Int32(second)
        let seconds = timegm(&parts)
        return Int64(seconds) * 1_000_000_000 + nanosecond
    }

    /// The digits of `text` from `start` for `count` characters, as a number.
    private static func number(_ bytes: [UInt8], _ start: Int, _ count: Int) -> Int? {
        guard start + count <= bytes.count else { return nil }
        var value = 0
        for byte in bytes[start..<start + count] {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            value = value * 10 + Int(byte - 0x30)
        }
        return value
    }

    /// The fraction after a dot at `start`, in nanoseconds, and where it ends.
    private static func fraction(_ bytes: [UInt8], _ start: Int) -> (Int64, Int) {
        guard start < bytes.count, bytes[start] == UInt8(ascii: ".") else { return (0, start) }
        var value: Int64 = 0
        var digits = 0
        var index = start + 1
        while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
            if digits < 9 {
                value = value * 10 + Int64(bytes[index] - 0x30)
                digits += 1
            }
            index += 1
        }
        for _ in digits..<9 { value *= 10 }
        return (value, index)
    }

    /// `2009-10-12T17:50:30.000Z`, as S3 lists it. Always UTC.
    static func iso8601(_ text: String) -> Int64? {
        let bytes = Array(text.utf8)
        guard bytes.count >= 19, let year = number(bytes, 0, 4), let month = number(bytes, 5, 2), let day = number(bytes, 8, 2),
              let hour = number(bytes, 11, 2), let minute = number(bytes, 14, 2), let second = number(bytes, 17, 2)
        else { return nil }
        let (nanosecond, _) = fraction(bytes, 19)
        return nanoseconds(year: year, month: month, day: day, hour: hour, minute: minute, second: second, nanosecond: nanosecond)
    }

    /// `20240105143000` or `20240105143000.123`, the `modify` fact of FTP's MLSD (RFC 3659). UTC.
    static func mlsd(_ text: String) -> Int64? {
        let bytes = Array(text.utf8)
        guard bytes.count >= 14, let year = number(bytes, 0, 4), let month = number(bytes, 4, 2), let day = number(bytes, 6, 2),
              let hour = number(bytes, 8, 2), let minute = number(bytes, 10, 2), let second = number(bytes, 12, 2)
        else { return nil }
        let (nanosecond, _) = fraction(bytes, 14)
        return nanoseconds(year: year, month: month, day: day, hour: hour, minute: minute, second: second, nanosecond: nanosecond)
    }
}
