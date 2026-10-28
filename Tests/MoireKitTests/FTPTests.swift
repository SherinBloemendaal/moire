import Foundation
@testable import MoireKit
import Testing

struct FTPListingTests {
    @Test func `reads MLSD facts`() {
        let text = """
            type=cdir;sizd=4096;modify=20240105143000;perm=flcdmpe; .
            type=pdir;sizd=4096;modify=20240105143000;perm=flcdmpe; ..
            type=file;size=1234;modify=20240105143000.250;UNIX.mode=0644; read me.txt
            Type=dir;Modify=20231231235959; src
            type=OS.unix=slink:/etc/my hosts;modify=20240101000000; hosts
            type=OS.unix=symlink;modify=20240101000000; other-link
            type=file;size=0;modify=19700101000000; ;semicolon name
            """
        let items = FTPListing.mlsd(Data(text.utf8))
        #expect(items.map(\.entry.name) == ["read me.txt", "src", "hosts", "other-link", ";semicolon name"])
        #expect(items[0].entry.kind == .file)
        #expect(items[0].entry.size == 1234)
        #expect(items[0].entry.modified == 1_704_465_000_250_000_000)
        #expect(items[1].entry.kind == .directory)
        #expect(items[1].entry.size == 0)
        #expect(items[2].entry.kind == .symbolicLink)
        #expect(items[2].linkTarget == "/etc/my hosts")
        #expect(items[3].entry.kind == .symbolicLink)
        #expect(items[3].linkTarget == nil)
    }

    @Test func `reads Unix LIST lines`() {
        let now = Date(timeIntervalSince1970: 1_717_200_000) // 2024-06-01
        let text = """
            total 24
            -rw-r--r--    1 owner    group        1234 Mar  5 14:02 notes  with  spaces.txt
            drwxr-xr-x    2 owner    group        4096 Dec 24  2022 archive
            lrwxrwxrwx    1 owner    group           7 Jan  1 00:00 current -> v2.1/app
            -rw-r--r--    1 ftp      0 Oct 10 09:15 no-group.bin
            -rw-r--r--    1 owner    group          10 Dec 30 23:59 last-year.txt
            """
        let items = FTPListing.list(Data(text.utf8), now: now)
        #expect(items.map(\.entry.name) == ["notes  with  spaces.txt", "archive", "current", "no-group.bin", "last-year.txt"])
        #expect(items[0].entry.size == 1234)
        #expect(items[0].entry.modified == 1_709_647_320_000_000_000) // 2024-03-05 14:02 UTC
        #expect(items[1].entry.kind == .directory)
        #expect(items[1].entry.modified == 1_671_840_000_000_000_000) // 2022-12-24
        #expect(items[2].entry.kind == .symbolicLink)
        #expect(items[2].linkTarget == "v2.1/app")
        #expect(items[3].entry.size == 0)
        // December has not come yet in June, so it was last December.
        #expect(items[4].entry.modified == 1_703_980_740_000_000_000) // 2023-12-30 23:59 UTC
    }

    @Test func `reads DOS LIST lines`() {
        let text = """
            01-05-24  02:30PM       <DIR>          Program Files
            12-31-99  12:05AM                 1024 old file.dat
            """
        let items = FTPListing.list(Data(text.utf8))
        #expect(items.map(\.entry.name) == ["Program Files", "old file.dat"])
        #expect(items[0].entry.kind == .directory)
        #expect(items[0].entry.modified == 1_704_465_000_000_000_000)
        #expect(items[1].entry.size == 1024)
        #expect(items[1].entry.modified == 946_598_700_000_000_000) // 1999-12-31 00:05
    }

    @Test func `skips lines it does not understand`() {
        #expect(FTPListing.list(Data("garbage\n\nthis is not a listing\n".utf8)).isEmpty)
        #expect(FTPListing.mlsd(Data("nospace\n".utf8)).isEmpty)
    }
}

struct FTPSourceTests {
    @Test func `quotes the login for a curl config`() {
        let curl = Curl(user: "me", password: "p\"a\\ss\nword", requireTLS: true)
        #expect(curl.config == "user = \"me:p\\\"a\\\\ss\\nword\"\n")
        #expect(curl.options.first == "-q")
        #expect(curl.options.contains("--ssl-reqd"))
        #expect(!curl.options.joined().contains("word"))
    }

    @Test func `paths are relative to the login folder unless they start with %2F`() {
        #expect(FTPSource.encodedPath("") == "")
        #expect(FTPSource.encodedPath("/pub/my files") == "/pub/my%20files")
        #expect(FTPSource.encodedPath("//srv/ftp") == "/%2F/srv/ftp")
    }

    @Test func `shortens curl's error messages`() {
        #expect(Curl.message("curl: (67) Access denied: 530", code: 67) == "Access denied: 530")
        #expect(Curl.message("", code: 7) == "curl ended with exit code 7.")
    }

    /// A stand-in for curl that prints a fixed listing, so the source's own work is tested without
    /// a server: the arguments, the config on standard input, and the MLSD fallback.
    @Test func `falls back to LIST when the server has no MLSD`() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "moire-curl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appending(path: "curl")
        let log = folder.appending(path: "log")
        try """
            #!/bin/sh
            cat > /dev/null
            echo "$@" >> '\(log.path(percentEncoded: false))'
            case "$*" in
              *MLSD*) echo "curl: (19) RETR response: 500" >&2; exit 19 ;;
              *" -r "*) printf 'ell' ;;
              *ftp://host/pub/a.txt) printf 'hello' ;;
              *) printf -- '-rw-r--r-- 1 o g 5 Jan  1  2024 a.txt\\r\\ndrwxr-xr-x 2 o g 0 Jan  1  2024 dir\\r\\n' ;;
            esac
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))

        let location = RemoteLocation(scheme: .ftp, user: "me", host: "host", path: "/pub")
        let source = try FTPSource(location: location, curl: Curl(executable: script.path(percentEncoded: false), user: "me", password: "secret", requireTLS: false))
        let entries = try source.list("", skipHidden: true)
        #expect(entries.map(\.name) == ["a.txt", "dir"])
        #expect(entries.map(\.size) == [5, 0])
        let file = try source.open("a.txt", listedSize: 5)
        #expect(try file.read(at: 1, count: 3) == Data("ell".utf8))
        #expect(try file.readAll() == Data("hello".utf8))
        _ = try source.list("dir", skipHidden: true)

        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        // MLSD is tried once; after LIST worked, it is not asked for again.
        #expect(calls.filter { $0.contains("MLSD") }.count == 1)
        #expect(calls.contains { $0.hasSuffix("ftp://host/pub/dir/") && !$0.contains("MLSD") })
        #expect(!calls.joined().contains("secret"))
    }

    @Test func `reports a failed login without trying other commands`() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "moire-curl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appending(path: "curl")
        try "#!/bin/sh\ncat > /dev/null\necho 'curl: (67) Access denied: 530' >&2\nexit 67\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
        let location = RemoteLocation(scheme: .ftp, user: "me", host: "host")
        #expect(throws: RemoteError("ftp://me@host: Access denied: 530")) {
            try FTPSource(location: location, curl: Curl(executable: script.path(percentEncoded: false), user: "me", password: "x", requireTLS: false))
        }
    }
}
