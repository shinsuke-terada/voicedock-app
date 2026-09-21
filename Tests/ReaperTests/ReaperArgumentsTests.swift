// voicedock-reaper の引数・--version・RV-00（T-37 §5.1。層 R1。ビルドした実行ファイルを起動して外から観測する）。
import Foundation
import TestSupport
import Testing
import VDContract

@Suite("voicedock-reaper の引数と置き場所（層 R1）")
struct ReaperArgumentsTests {
    /// reaper の実行ファイルを dir の下に複製する（chmod 0o755）
    static func copyReaper(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: ReaperBinary.url()).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    }

    /// 「何も書かれない」: ログが無い・要求が残る・結果も退避も processed.log も無い・デバイス上のファイルが在る
    static func expectNothingWritten(_ bench: ReaperBench, request name: String?) {
        #expect(!FileManager.default.fileExists(atPath: bench.layout.reaperLog.path(percentEncoded: false)))
        #expect(bench.requests() == (name.map { [$0] } ?? []))
        #expect(bench.results() == [])
        #expect(bench.rejected() == [])
        #expect(bench.processedLines() == [])
        #expect(bench.sourceExists())
    }

    @Test("--version は版だけを出す")
    func versionIsPrintedAndNothingElseHappens() throws {
        let bench = try ReaperBench()
        let name = try bench.writeRequest()
        let run = try ReaperBinary.run(executable: bench.layout.reaperExecutable, arguments: ["--version"])
        #expect(run.exitCode == 0)
        #expect(run.stdout == AppVersion.string + "\n")
        #expect(run.stderr == "")
        Self.expectNothingWritten(bench, request: name)
    }

    @Test("RV-00 --version は置き場所の検査より前")
    func versionWorksBeforeTheLocationCheck() throws {
        let bench = try ReaperBench()
        let name = try bench.writeRequest()
        // ビルド元の実行ファイル（<HOME>/bin の外）
        let run = try ReaperBinary.run(executable: ReaperBinary.url(), arguments: ["--version"])
        #expect(run.exitCode == 0)
        #expect(run.stdout == AppVersion.string + "\n")
        #expect(run.stderr == "")
        Self.expectNothingWritten(bench, request: name)
    }

    @Test("ND-40 [R1] バンドル内の reaper を起動しても何も消えず何も書かれない")
    func nd40BundledReaperDoesNothing() throws {
        let bench = try ReaperBench()
        let name = try bench.writeRequest()
        let bundled = bench.tmp.url.appendingPathComponent("VoiceDock.app/Contents/Helpers/voicedock-reaper")
        try Self.copyReaper(to: bundled)
        let run = try ReaperBinary.run(
            executable: bundled, arguments: ["--home", bench.layout.root.path(percentEncoded: false)])
        #expect(run.exitCode == 3)
        #expect(run.stdout == "")
        #expect(run.stderr == "")
        Self.expectNothingWritten(bench, request: name)
    }

    @Test("ND-40 [R1] <HOME>/bin 以外の場所からの起動は 3")
    func nd40AnyOtherPlaceIsRefused() throws {
        let bench = try ReaperBench()
        let name = try bench.writeRequest()
        let elsewhere = bench.tmp.url.appendingPathComponent("elsewhere/voicedock-reaper")
        try Self.copyReaper(to: elsewhere)
        let run = try ReaperBinary.run(
            executable: elsewhere, arguments: ["--home", bench.layout.root.path(percentEncoded: false)])
        #expect(run.exitCode == 3)
        #expect(run.stdout == "")
        #expect(run.stderr == "")
        Self.expectNothingWritten(bench, request: name)
    }

    @Test("RV-00 <HOME>/bin/voicedock-reaper が symlink なら 3")
    func rv00SymlinkedReaperIsRefused() throws {
        let bench = try ReaperBench()
        let name = try bench.writeRequest()
        let real = bench.layout.root.appendingPathComponent("bin/real")
        try FileManager.default.moveItem(at: bench.layout.reaperExecutable, to: real)
        try FileManager.default.createSymbolicLink(
            atPath: bench.layout.reaperExecutable.path(percentEncoded: false), withDestinationPath: "real")
        let run = try bench.run()
        #expect(run.exitCode == 3)
        #expect(run.stdout == "")
        #expect(run.stderr == "")
        Self.expectNothingWritten(bench, request: name)
    }

    @Test("RV-00 別の --home を渡すと 3")
    func rv00AnotherHomeIsRefused() throws {
        let a = try ReaperBench()
        let b = try ReaperBench()
        let nameA = try a.writeRequest()
        let nameB = try b.writeRequest()
        let run = try ReaperBinary.run(
            executable: a.layout.reaperExecutable, arguments: ["--home", b.layout.root.path(percentEncoded: false)])
        #expect(run.exitCode == 3)
        #expect(run.stdout == "")
        #expect(run.stderr == "")
        Self.expectNothingWritten(a, request: nameA)
        Self.expectNothingWritten(b, request: nameB)
    }

    /// 置き場所の一致の検査は通るので、`.app/Contents/` の検査だけが弾く（T-37 §4.5 の手順 2 を手順 5 より先に置く理由）
    @Test("RV-00 <HOME> が .app/Contents/ の下なら 3")
    func rv00HomeInsideABundleIsRefused() throws {
        let bench = try ReaperBench()
        try bench.writeRequest()
        let contents = bench.tmp.url.appendingPathComponent("VoiceDock.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let home = contents.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.moveItem(at: bench.layout.root, to: home)
        let moved = HomeLayout(root: home)
        let run = try ReaperBinary.run(
            executable: moved.reaperExecutable, arguments: ["--home", home.path(percentEncoded: false)])
        #expect(run.exitCode == 3)
        #expect(run.stdout == "")
        #expect(run.stderr == "")
        #expect(!FileManager.default.fileExists(atPath: moved.reaperLog.path(percentEncoded: false)))
        let requests = try FileManager.default.contentsOfDirectory(
            atPath: moved.queueDelete.path(percentEncoded: false))
        #expect(requests == [ReaperBench.requestID + ".json"])
        let results = try FileManager.default.contentsOfDirectory(atPath: moved.queueResult.path(percentEncoded: false))
        #expect(results == [])
        #expect(bench.sourceExists())
    }

    @Test("RV-00 --home が無いディレクトリなら 3")
    func rv00MissingHomeIsRefused() throws {
        let bench = try ReaperBench()
        let name = try bench.writeRequest()
        let nope = bench.tmp.url.appendingPathComponent("nope", isDirectory: true)
        let run = try ReaperBinary.run(
            executable: bench.layout.reaperExecutable, arguments: ["--home", nope.path(percentEncoded: false)])
        #expect(run.exitCode == 3)
        #expect(run.stdout == "")
        #expect(run.stderr == "")
        #expect(!FileManager.default.fileExists(atPath: nope.path(percentEncoded: false)))
        Self.expectNothingWritten(bench, request: name)
    }

    /// `<HOME>` は実行時に舞台の HOME に置き換える
    @Test(
        "引数が不正なら 2（キューに触らない）",
        arguments: [
            [], ["--help"], ["-h"], ["--home"], ["--home", "<HOME>", "--x"], ["--version", "x"],
        ] as [[String]])
    func badArgumentsExitTwo(_ arguments: [String]) throws {
        let bench = try ReaperBench()
        let name = try bench.writeRequest()
        let home = bench.layout.root.path(percentEncoded: false)
        let run = try ReaperBinary.run(
            executable: bench.layout.reaperExecutable, arguments: arguments.map { $0 == "<HOME>" ? home : $0 })
        #expect(run.exitCode == 2)
        #expect(run.stdout == "")
        #expect(run.stderr == "usage: voicedock-reaper --home <HOME> | --version\n")
        Self.expectNothingWritten(bench, request: name)
    }
}
