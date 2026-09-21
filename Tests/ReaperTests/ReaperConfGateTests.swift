// reaper.conf とロック 1（T-37 §5.2。層 R1。ビルドした実行ファイルを起動して外から観測する）。
import Foundation
import TestSupport
import Testing
import VDContract

@Suite("reaper.conf とロック 1（層 R1）")
struct ReaperConfGateTests {
    static let confInvalidLine = "INFO  reaper_disabled reason=conf_invalid"

    /// 共通の準備: 舞台 ＋ 通る要求 1 件
    static func bench() throws -> (ReaperBench, String) {
        let bench = try ReaperBench()
        let name = try bench.writeRequest()
        return (bench, name)
    }

    /// 「要求に触らない」
    static func expectUntouched(_ bench: ReaperBench, _ name: String) {
        #expect(bench.requests() == [name])
        #expect(bench.results() == [])
        #expect(bench.rejected() == [])
        #expect(bench.processedLines() == [])
        #expect(bench.sourceExists())
    }

    static func logged(_ bench: ReaperBench, _ tail: String) -> Bool {
        bench.logLines().contains { $0.hasSuffix(" " + tail) }
    }

    /// 無効側: exit 2、`reaper_disabled reason=conf_invalid`、要求に触らない
    static func expectInvalid(_ bench: ReaperBench, _ name: String) throws {
        let run = try bench.run()
        #expect(run.exitCode == 2)
        #expect(logged(bench, confInvalidLine))
        expectUntouched(bench, name)
    }

    @Test("ND-22 [R1] reaper.conf の DELETE_SOURCE_AUDIO=false なら要求に触らない")
    func nd22Lock1FalseTouchesNothing() throws {
        let (bench, name) = try Self.bench()
        try bench.writeReaperConf(deleteSourceAudio: false)
        let run = try bench.run()
        #expect(run.exitCode == 0)
        #expect(Self.logged(bench, "INFO  reaper_disabled reason=lock1"))
        Self.expectUntouched(bench, name)
    }

    @Test("ND-43 [R1] 未知のキーは無効側")
    func nd43UnknownKeyIsInvalid() throws {
        let (bench, name) = try Self.bench()
        try bench.writeReaperConfRaw("SCHEMA=1\nDELETE_SOURCE_AUDIO=true\nEXTRA=1\n")
        try Self.expectInvalid(bench, name)
    }

    @Test("ND-43 [R1] 重複したキーは無効側")
    func nd43DuplicateKeyIsInvalid() throws {
        let (bench, name) = try Self.bench()
        let root = bench.volumesRoot.path(percentEncoded: false)
        try bench.writeReaperConfRaw(
            "SCHEMA=1\nDELETE_SOURCE_AUDIO=true\nDELETE_SOURCE_AUDIO=true\nVOLUMES_ROOT=" + root + "\n")
        try Self.expectInvalid(bench, name)
    }

    /// `<ROOT>` は実行時に舞台の volumesRoot に置き換える
    @Test(
        "ND-43 [R1] 不正な値は無効側",
        arguments: [
            "SCHEMA=1\nDELETE_SOURCE_AUDIO=yes\nVOLUMES_ROOT=<ROOT>\n",
            "SCHEMA=2\nDELETE_SOURCE_AUDIO=true\nVOLUMES_ROOT=<ROOT>\n",
            "SCHEMA=1\nDELETE_SOURCE_AUDIO=true\nVOLUMES_ROOT=rel\n",
        ])
    func nd43BadValueIsInvalid(_ text: String) throws {
        let (bench, name) = try Self.bench()
        let root = bench.volumesRoot.path(percentEncoded: false)
        try bench.writeReaperConfRaw(text.replacingOccurrences(of: "<ROOT>", with: root))
        try Self.expectInvalid(bench, name)
    }

    @Test("ND-43 [R1] 必須のキーが欠けていたら無効側", arguments: ["SCHEMA=1\n", "DELETE_SOURCE_AUDIO=true\n"])
    func nd43MissingKeyIsInvalid(_ text: String) throws {
        let (bench, name) = try Self.bench()
        try bench.writeReaperConfRaw(text)
        try Self.expectInvalid(bench, name)
    }

    @Test(
        "ND-43 [R1] 書式に合わない行は無効側",
        arguments: [
            "SCHEMA=1\ndelete_source_audio=true\nVOLUMES_ROOT=<ROOT>\n",
            "SCHEMA = 1\nDELETE_SOURCE_AUDIO=true\nVOLUMES_ROOT=<ROOT>\n",
        ])
    func nd43MalformedLineIsInvalid(_ text: String) throws {
        let (bench, name) = try Self.bench()
        let root = bench.volumesRoot.path(percentEncoded: false)
        try bench.writeReaperConfRaw(text.replacingOccurrences(of: "<ROOT>", with: root))
        try Self.expectInvalid(bench, name)
    }

    @Test("reaper.conf が無ければ無効側")
    func missingConfIsInvalid() throws {
        let (bench, name) = try Self.bench()
        try bench.removeReaperConf()
        try Self.expectInvalid(bench, name)
    }

    @Test("reaper.conf が symlink なら無効側")
    func symlinkedConfIsInvalid() throws {
        let (bench, name) = try Self.bench()
        let other = bench.layout.root.appendingPathComponent("bin/other.conf")
        try FileManager.default.moveItem(at: bench.layout.reaperConf, to: other)
        try FileManager.default.createSymbolicLink(
            atPath: bench.layout.reaperConf.path(percentEncoded: false), withDestinationPath: "other.conf")
        try Self.expectInvalid(bench, name)
    }

    @Test("reaper.conf が 64 KiB を超えたら無効側")
    func oversizedConfIsInvalid() throws {
        let (bench, name) = try Self.bench()
        let root = bench.volumesRoot.path(percentEncoded: false)
        let valid = "SCHEMA=1\nDELETE_SOURCE_AUDIO=true\nVOLUMES_ROOT=" + root + "\n"
        // 全体が 65_537 バイト（上限 65_536 の 1 バイト超え）になるように # の行で埋める
        let padding = "#" + String(repeating: "x", count: 65_537 - valid.utf8.count - 2) + "\n"
        let text = valid + padding
        #expect(text.utf8.count == 65_537)
        try bench.writeReaperConfRaw(text)
        try Self.expectInvalid(bench, name)
    }

    @Test("空行と # の行は無視される（対照）")
    func commentsAndBlankLinesArePassed() throws {
        let (bench, _) = try Self.bench()
        let root = bench.volumesRoot.path(percentEncoded: false)
        try bench.writeReaperConfRaw(
            "\n# head\n\nSCHEMA=1\n\n# middle\nDELETE_SOURCE_AUDIO=true\nVOLUMES_ROOT=" + root + "\n\n# tail\n")
        let run = try bench.run()
        #expect(run.exitCode == 0)
        #expect(bench.requests() == [])
        #expect(try bench.result(ReaperBench.requestID).detail == "not_a_mount_point")
    }
}
