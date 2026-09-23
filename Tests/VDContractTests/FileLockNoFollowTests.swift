// FileLock はロックファイルの symlink を辿らない（F-73・issue #113。O_NOFOLLOW）。
import Foundation
import TestSupport
import Testing

@testable import VDContract

@Suite("FileLock は symlink を辿らない（F-73）")
struct FileLockNoFollowTests {
    @Test("F-73 ロックのパスが symlink なら取れず、辿った先を作らない・書き換えない", arguments: [true, false])
    func f73SymlinkedLockIsNotFollowed(_ targetExists: Bool) throws {
        let tmp = try TempDirectory()
        let outside = tmp.url.appendingPathComponent("outside.lock")
        if targetExists { try Data("keep".utf8).write(to: outside) }
        let lockURL = tmp.url.appendingPathComponent("reaper.lock")
        try FileManager.default.createSymbolicLink(
            atPath: lockURL.path(percentEncoded: false), withDestinationPath: outside.path(percentEncoded: false))
        #expect(FileLock.tryAcquire(url: lockURL) == nil)
        if targetExists {
            #expect(try Data(contentsOf: outside) == Data("keep".utf8))
        } else {
            #expect(!FileManager.default.fileExists(atPath: outside.path(percentEncoded: false)))
        }
    }

    @Test("F-73 対照: symlink でなければ作って取れる")
    func f73PlainLockIsAcquired() throws {
        let tmp = try TempDirectory()
        let lockURL = tmp.url.appendingPathComponent("reaper.lock")
        let lock = FileLock.tryAcquire(url: lockURL)
        #expect(lock != nil)
        #expect(try Data(contentsOf: lockURL) == Data())
        lock?.release()
    }
}
