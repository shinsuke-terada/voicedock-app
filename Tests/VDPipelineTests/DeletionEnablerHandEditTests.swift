// 手で編集された・壊れた config.json での無効化（F-83。PLAN §6.1・§8.9.8。issue #119 の H4）。
// update は今のファイルを読み直して変更を当てる。壊れていて書けなければメモリだけ無効側に倒し、理由をログに出す。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore

@testable import VDPipeline

@Suite("DeletionEnabler（F-83）", .serialized, .timeLimit(.minutes(1)))
struct DeletionEnablerHandEditTests {
    static func fileConfig(_ bench: EnablerBench) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: try Data(contentsOf: bench.layout.configFile))
    }

    @Test("F-83 手編集の後の無効化が成功し、手編集は残り mountMode は ro になる（偽の CV-30 が出ない）")
    func disableAfterHandEditSucceeds() async throws {
        let bench = try await EnablerBench(enabled: true)
        var edited = try Self.fileConfig(bench)
        edited.llm.temperature = 1.5
        try AtomicFile.write(try ConfigLoader.encode(edited), to: bench.layout.configFile)
        let failed = await bench.enabler.disable()
        #expect(failed == [])
        let written = try Self.fileConfig(bench)
        #expect(written.llm.temperature == 1.5)
        #expect(written.cleanup.deleteSourceAudio == false)
        #expect(written.cleanup.deleteSkippedSource == false)
        #expect(written.device.mountMode == "ro")
        #expect(try #require(await bench.config()) == written)
        #expect(bench.logLines().filter { $0.contains(" config_warning ") }.isEmpty)
    }

    @Test("F-83 壊れた config.json には書かず、メモリだけ無効側に倒し、理由をログに出す")
    func brokenFileIsLeftAndMemoryIsTurnedOff() async throws {
        let bench = try await EnablerBench(enabled: true)
        try Data("{".utf8).write(to: bench.layout.configFile)
        let failed = await bench.enabler.disable()
        #expect(failed == ["config"])
        #expect(try Data(contentsOf: bench.layout.configFile) == Data("{".utf8))
        let c = try #require(await bench.config())
        #expect(c.cleanup.deleteSourceAudio == false)
        #expect(c.cleanup.deleteSkippedSource == false)
        #expect(c.device.mountMode == "ro")
        guard case .valid(let conf) = bench.reaperConf() else {
            Issue.record("reaper.conf が読めない")
            return
        }
        #expect(conf.deleteSourceAudio == false)
        #expect(
            bench.logLines().contains {
                $0.contains(
                    " config_warning rule=CV-39 message=\"無効化で config.json を書けません（メモリの設定だけ無効側にしました）: <file>: JSON として読めません\""
                )
            })
        #expect(await bench.ingest.scanNowCalls == 1)
    }

    @Test("F-83 空にされた config.json（TEST-28）にも書かず、メモリだけ無効側に倒す")
    func emptiedFileIsLeftAndMemoryIsTurnedOff() async throws {
        let bench = try await EnablerBench(enabled: true)
        try Data().write(to: bench.layout.configFile)
        #expect(await bench.enabler.disable() == ["config"])
        #expect(try Data(contentsOf: bench.layout.configFile) == Data())
        let c = try #require(await bench.config())
        #expect(c.cleanup.deleteSourceAudio == false)
        #expect(c.device.mountMode == "ro")
    }

    @Test("F-83 手編集の後の有効化も、手編集を残して今のファイルの上に書く")
    func enableAfterDisableUsesTheCurrentFile() async throws {
        let bench = try await EnablerBench()
        var edited = try Self.fileConfig(bench)
        edited.llm.temperature = 0.5
        try AtomicFile.write(try ConfigLoader.encode(edited), to: bench.layout.configFile)
        let r = await bench.enabler.enable(confirmation: "ENABLE")
        guard case .success = r else {
            Issue.record("有効化に失敗した: \(r)")
            return
        }
        let written = try Self.fileConfig(bench)
        #expect(written.llm.temperature == 0.5)
        #expect(written.cleanup.deleteSourceAudio == true)
        #expect(written.device.mountMode == "rw")
    }
}
