// FileLock が取れなかった理由（F-84・issue #119。F-76 の残り）。ほかが持っている（EWOULDBLOCK）と開けないを分ける。
import Foundation
import TestSupport
import Testing

@testable import VDContract

@Suite("FileLock の取れなかった理由（F-84）", .serialized)
struct FileLockFailureTests {
    static func failure(_ r: Result<FileLock, FileLock.Failure>) -> FileLock.Failure? {
        if case .failure(let f) = r { return f }
        return nil
    }

    @Test("F-84 ほかが持っていれば held（EWOULDBLOCK。tryAcquire は従来どおり nil）")
    func heldByAnother() throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("app.lock")
        let first = try FileLock.tryAcquireResult(url: url).get()
        withExtendedLifetime(first) {
            #expect(Self.failure(FileLock.tryAcquireResult(url: url)) == .held)
            #expect(FileLock.tryAcquire(url: url) == nil)
        }
    }

    @Test("F-84 取れれば success（手放せば取り直せる。tryAcquire も取れる）")
    func acquiredWhenFree() throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("app.lock")
        do {
            let lock = try FileLock.tryAcquireResult(url: url).get()
            lock.release()
            #expect(Self.failure(FileLock.tryAcquireResult(url: url)) == nil)
        }
        #expect(FileLock.tryAcquire(url: url) != nil)
    }

    @Test("F-84 親ディレクトリが無ければ openFailed(ENOENT)（何も作らない）")
    func missingParentIsENOENT() throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let dir = tmp.url.appendingPathComponent("state", isDirectory: true)
        let url = dir.appendingPathComponent("app.lock")
        #expect(Self.failure(FileLock.tryAcquireResult(url: url)) == .openFailed(errno: 2))
        #expect(!FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)))
    }

    @Test("F-84 ロックファイルが symlink なら openFailed(ELOOP)（辿った先に作らない。F-73）")
    func symlinkIsELOOP() throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("app.lock")
        let target = tmp.url.appendingPathComponent("elsewhere.lock")
        try FileManager.default.createSymbolicLink(
            atPath: url.path(percentEncoded: false), withDestinationPath: target.path(percentEncoded: false))
        #expect(Self.failure(FileLock.tryAcquireResult(url: url)) == .openFailed(errno: 62))
        #expect(!FileManager.default.fileExists(atPath: target.path(percentEncoded: false)))
    }

    @Test("F-84 ロックファイルの場所がディレクトリなら openFailed(EISDIR)")
    func directoryIsEISDIR() throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("app.lock", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(Self.failure(FileLock.tryAcquireResult(url: url)) == .openFailed(errno: 21))
    }

    @Test("F-84 書けないディレクトリでは openFailed(EACCES)")
    func unwritableDirectoryIsEACCES() throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let dir = tmp.url.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path(percentEncoded: false))
        // 消す前に書けるように戻す（TempDirectory の後始末のため）
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: dir.path(percentEncoded: false))
        }
        let url = dir.appendingPathComponent("app.lock")
        #expect(Self.failure(FileLock.tryAcquireResult(url: url)) == .openFailed(errno: 13))
    }
}
