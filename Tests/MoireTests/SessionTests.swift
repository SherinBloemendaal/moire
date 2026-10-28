import Foundation
@testable import Moire
import Testing

struct SessionTests {
    private let folders = ComparisonSession(
        kind: .folders, left: "/Users/me/app", right: "/Users/me/app-v2",
        method: "quick", skipHidden: false, include: "*.swift", exclude: "build/", useGitignore: true
    )

    @Test func `round trips through a saved file`() throws {
        let data = try JSONEncoder().encode(folders)
        #expect(try JSONDecoder().decode(ComparisonSession.self, from: data) == folders)
    }

    @Test func `reads a file written before new settings existed`() throws {
        let old = #"{"kind":"text","left":"/a.txt","right":"/b.txt"}"#
        let session = try JSONDecoder().decode(ComparisonSession.self, from: Data(old.utf8))
        #expect(session.kind == .text)
        #expect(session.method == nil)
    }

    @Test func `names itself after both sides`() {
        #expect(folders.title == "app ⇄ app-v2")
        #expect(folders.subtitle == "Folders · /Users/me")
    }

    @Test func `keeps the newest comparisons first without duplicates`() {
        let recents = RecentSessions()
        defer { recents.clear() }
        recents.clear()
        for index in 0..<20 {
            recents.note(ComparisonSession(kind: .text, left: "/l\(index)", right: "/r\(index)"))
        }
        recents.note(ComparisonSession(kind: .text, left: "/l5", right: "/r5", ignoreCase: true))
        #expect(recents.sessions.count == 15)
        #expect(recents.sessions.first?.left == "/l5")
        #expect(recents.sessions.first?.ignoreCase == true)
        #expect(recents.sessions.filter { $0.left == "/l5" }.count == 1)
        // A comparison with one side missing is not worth remembering.
        recents.note(ComparisonSession(kind: .text, left: "/only", right: nil))
        #expect(recents.sessions.first?.left == "/l5")
    }
}
