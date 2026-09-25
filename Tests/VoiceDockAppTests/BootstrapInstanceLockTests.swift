// 単一起動のロック（F-76・issue #116。PLAN §2.3・§8.15）。Bootstrap の判定の関数を一時ディレクトリの HOME で試す。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VoiceDockApp

@Suite("Bootstrap（単一起動）")
struct BootstrapInstanceLockTests {
    static func home(_ tmp: TempDirectory) -> HomeLayout {
        HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    /// 取れなかった理由（取れたら nil。F-84 で acquireInstanceLock が Result を返すようになった）
    static func failure(_ r: Result<FileLock, BootFailure>) -> BootFailure? {
        if case .failure(let f) = r { return f }
        return nil
    }

    @Test("F-76 単一起動のロックは state/app.lock（reaper.lock とは別のファイル）")
    func lockPathIsSeparateFromReaperLock() {
        let layout = HomeLayout(root: URL(fileURLWithPath: "/tmp/VoiceDockInstanceLockTests", isDirectory: true))
        #expect(layout.relativePath(of: layout.appLock) == "state/app.lock")
        #expect(layout.relativePath(of: layout.reaperLock) == "state/reaper.lock")
    }

    @Test("F-76 2 つ目の起動はロックを取れない（先の起動が手放せば取れる）")
    func secondLaunchCannotLock() throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let layout = Self.home(tmp)
        try layout.createDirectories()
        do {
            let first = try Bootstrap.acquireInstanceLock(layout: layout).get()
            withExtendedLifetime(first) {
                #expect(Self.failure(Bootstrap.acquireInstanceLock(layout: layout)) == .alreadyRunning)
            }
            #expect(Self.exists(layout.appLock))
        }
        // 先の起動が終わる（fd が閉じる）と、次の起動は取れる
        #expect(Self.failure(Bootstrap.acquireInstanceLock(layout: layout)) == nil)
    }

    @Test("F-76 reaper が reaper.lock を持っていても起動できる（削除の実行と起動の判定が混ざらない）")
    func reaperLockDoesNotBlockLaunch() throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let layout = Self.home(tmp)
        try layout.createDirectories()
        let reaper = try #require(FileLock.tryAcquire(url: layout.reaperLock))
        let app = try Bootstrap.acquireInstanceLock(layout: layout).get()
        withExtendedLifetime((reaper, app)) {
            // アプリのロックを持ったままでも、reaper は reaper.lock を取れる（次の reaper を真似て、手放してから取り直す）
            reaper.release()
            #expect(FileLock.tryAcquire(url: layout.reaperLock) != nil)
        }
    }

    @Test("F-84 空の HOME（state が無い）では app.lock を開けず、起動の失敗（NSAlert）にして何も作らない（F-76。ディレクトリを作ってから取る）")
    func emptyHomeCannotLock() throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let layout = Self.home(tmp)
        // F-84: 別のインスタンスではないので、黙って終わらずに起動の失敗として知らせる
        #expect(
            Self.failure(Bootstrap.acquireInstanceLock(layout: layout))
                == .instanceLock(path: "state/app.lock", reason: "open: errno 2 (No such file or directory)"))
        #expect(!Self.exists(layout.root))
    }

    @Test("F-76 2 つ目の起動は警告を出さずに終わる（service_stopping の reason は already_running）")
    func alreadyRunningIsSilent() {
        #expect(BootFailure.alreadyRunning.message == nil)
        #expect(BootFailure.database("x").message == "データベースを開けません: x")
        #expect(Bootstrap.alreadyRunningReason == "already_running")
    }
}
