// 単一起動のロックを開けないとき（F-84・issue #119。F-76 の残り）。別のインスタンスではないので、黙って終わらずに NSAlert で知らせる。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VoiceDockApp

@Suite("Bootstrap（単一起動のロックを開けない。F-84）", .serialized)
struct BootstrapInstanceLockFailureTests {
    static func home(_ tmp: TempDirectory) throws -> HomeLayout {
        let layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
        try layout.createDirectories()
        return layout
    }

    static func failure(_ r: Result<FileLock, BootFailure>) -> BootFailure? {
        if case .failure(let f) = r { return f }
        return nil
    }

    @Test("F-84 state/ に書けなければ alreadyRunning ではなく起動の失敗（NSAlert の本文を出す）")
    func unwritableStateIsBootFailure() throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let layout = try Self.home(tmp)
        let state = layout.appLock.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: state.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: state.path(percentEncoded: false))
        }
        let f = Self.failure(Bootstrap.acquireInstanceLock(layout: layout))
        #expect(f == .instanceLock(path: "state/app.lock", reason: "open: errno 13 (Permission denied)"))
        #expect(f?.message == "単一起動のロック（state/app.lock）を開けません: open: errno 13 (Permission denied)")
    }

    @Test("F-84 app.lock がディレクトリなら起動の失敗（EISDIR）")
    func directoryLockIsBootFailure() throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let layout = try Self.home(tmp)
        try FileManager.default.createDirectory(at: layout.appLock, withIntermediateDirectories: false)
        #expect(
            Self.failure(Bootstrap.acquireInstanceLock(layout: layout))
                == .instanceLock(path: "state/app.lock", reason: "open: errno 21 (Is a directory)"))
    }

    @Test("F-84 app.lock が symlink なら起動の失敗（ELOOP。辿った先に作らない）")
    func symlinkLockIsBootFailure() throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let layout = try Self.home(tmp)
        let target = tmp.url.appendingPathComponent("elsewhere.lock")
        try FileManager.default.createSymbolicLink(
            atPath: layout.appLock.path(percentEncoded: false), withDestinationPath: target.path(percentEncoded: false))
        #expect(
            Self.failure(Bootstrap.acquireInstanceLock(layout: layout))
                == .instanceLock(path: "state/app.lock", reason: "open: errno 62 (Too many levels of symbolic links)"))
        #expect(!FileManager.default.fileExists(atPath: target.path(percentEncoded: false)))
    }

    @Test("F-84 ほかが持っているときだけ alreadyRunning（警告を出さない）")
    func onlyHeldIsAlreadyRunning() throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let layout = try Self.home(tmp)
        let first = try Bootstrap.acquireInstanceLock(layout: layout).get()
        withExtendedLifetime(first) {
            let f = Self.failure(Bootstrap.acquireInstanceLock(layout: layout))
            #expect(f == .alreadyRunning)
            #expect(f?.message == nil)
        }
    }

    @Test("F-84 errno の文言は「<段>: errno <n> (<strerror>)」")
    func errnoTextFormat() {
        #expect(Bootstrap.errnoText("flock", 45) == "flock: errno 45 (Operation not supported)")
        #expect(Bootstrap.errnoText("open", 28) == "open: errno 28 (No space left on device)")
    }
}
