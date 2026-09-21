// FileLock の検査（T-06 §5.14）。
import Foundation
import Synchronization
import TestSupport
import Testing

@testable import VDContract

@Suite("FileLock", .serialized)
struct FileLockTests {
    /// 別スレッドで取得を試みた結果を受け渡す箱。
    final class Outcome: Sendable {
        let acquired = Mutex<Bool?>(nil)
    }

    @Test("2 つ目は取れない")
    func secondAcquireFails() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("reaper.lock")
        let first = try #require(FileLock.tryAcquire(url: url))
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            let second = FileLock.tryAcquire(url: url)
            outcome.acquired.withLock { $0 = second != nil }
            done.signal()
        }
        thread.start()
        let waited = done.wait(timeout: .now() + 5)
        #expect(waited == .success, "2 つ目の tryAcquire が 5 秒以内に返らなかった")
        #expect(outcome.acquired.withLock { $0 } == false)
        first.release()
    }

    @Test("release の後は取れる")
    func releaseAllowsReacquire() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("reaper.lock")
        let first = try #require(FileLock.tryAcquire(url: url))
        first.release()
        first.release()
        let second = FileLock.tryAcquire(url: url)
        #expect(second != nil)
    }

    @Test("参照を捨てれば外れる")
    func deinitReleases() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("reaper.lock")
        do {
            let held = FileLock.tryAcquire(url: url)
            #expect(held != nil)
        }
        #expect(FileLock.tryAcquire(url: url) != nil)
    }

    @Test("ロックファイルを 0644 で作る")
    func createsLockFileWith0644() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("reaper.lock")
        let lock = FileLock.tryAcquire(url: url)
        #expect(lock != nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.posixPermissions] as? Int == 0o644)
        #expect(attributes[.size] as? Int == 0)
    }

    @Test("親ディレクトリが無ければ nil")
    func missingDirectoryIsNil() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("missing", isDirectory: true).appendingPathComponent("reaper.lock")
        #expect(FileLock.tryAcquire(url: url) == nil)
    }
}
