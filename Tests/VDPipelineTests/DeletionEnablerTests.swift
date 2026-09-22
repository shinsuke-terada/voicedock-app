// DeletionEnabler の有効化・無効化・根拠 B（PLAN §8.9.8。T-40 §6.1）。
import Foundation
import Synchronization
import TestSupport
import Testing
import VDContract
import VDCore

@testable import VDPipeline

@Suite("DeletionEnabler")
struct DeletionEnablerTests {
    static func count(_ bench: EnablerBench, _ event: String) -> Int {
        bench.logLines().filter { $0.contains(" " + event) }.count
    }

    /// 失敗の中身（成功なら nil）。Result<Void, _> は Void が Equatable でないので == で比べられない
    static func error(_ r: Result<Void, EnableError>) -> EnableError? {
        if case .failure(let e) = r { return e }
        return nil
    }

    static func names(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []).sorted()
    }

    /// config が false / ro のまま（根拠 B も false）
    static func expectOff(_ bench: EnablerBench) async throws {
        let c = try #require(await bench.config())
        #expect(c.cleanup.deleteSourceAudio == false)
        #expect(c.cleanup.deleteSkippedSource == false)
        #expect(c.device.mountMode == "ro")
    }

    /// config.json と <HOME> を書けなくする（layout.configFile を 0o444、layout.root を 0o555）。戻すのは restoreConfig
    static func blockConfig(_ bench: EnablerBench) throws {
        try bench.setPermissions(0o444, at: bench.layout.configFile)
        try bench.setPermissions(0o555, at: bench.layout.root)
    }

    static func restoreConfig(_ bench: EnablerBench) {
        try? bench.setPermissions(0o755, at: bench.layout.root)
        try? bench.setPermissions(0o644, at: bench.layout.configFile)
    }

    // MARK: - 有効化

    @Test("有効化で 3 つのロックが全部外れる")
    func enableTurnsAllThreeLocksOff() async throws {
        let bench = try await EnablerBench()
        let r = await bench.enabler.enable(confirmation: "ENABLE")
        #expect(Self.error(r) == nil)
        #expect(bench.reaperMode() == 0o755)
        #expect(bench.reaperConf() == .valid(ReaperConf(deleteSourceAudio: true, volumesRoot: "/Volumes")))
        let c = try #require(await bench.config())
        #expect(c.cleanup.deleteSourceAudio == true)
        #expect(c.device.mountMode == "rw")
        #expect(c.cleanup.deleteSkippedSource == false)
        #expect(bench.tmpCopyExists() == false)
        #expect(Self.count(bench, "deletion_enabled") == 1)
    }

    @Test("reaper.conf の中身は 3 行＋末尾改行")
    func enableWritesTheConfVerbatim() async throws {
        let bench = try await EnablerBench()
        _ = await bench.enabler.enable(confirmation: "ENABLE")
        let data = try Data(contentsOf: bench.layout.reaperConf)
        #expect(data == Data("SCHEMA=1\nDELETE_SOURCE_AUDIO=true\nVOLUMES_ROOT=/Volumes\n".utf8))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: bench.layout.reaperConf.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? Int) == 0o644)
    }

    @Test("署名を検証するのは複製した方")
    func enableVerifiesTheCopyNotTheBundle() async throws {
        let bench = try await EnablerBench()
        _ = await bench.enabler.enable(confirmation: "ENABLE")
        let expected = bench.layout.root.appendingPathComponent("bin/.voicedock-reaper.tmp")
        #expect(
            bench.verifier.verifiedURLs.map { $0.path(percentEncoded: false) } == [expected.path(percentEncoded: false)]
        )
    }

    @Test(
        "ENABLE 以外では何も変えない",
        arguments: ["enable", "ENABLE ", " ENABLE", "Y", "", "ＥＮＡＢＬＥ", "ENABLE\u{200B}", "ENABLE\n"])
    func enableRequiresTheExactWord(_ word: String) async throws {
        let bench = try await EnablerBench()
        let r = await bench.enabler.enable(confirmation: word)
        #expect(Self.error(r) == .notConfirmed)
        #expect(bench.reaperIsInstalled() == false)
        #expect(bench.reaperConf() == .missing)
        try await Self.expectOff(bench)
        #expect(bench.logLines().isEmpty)
    }

    @Test("署名が通らなければ 1 つも変わらない")
    func enableRollsBackWhenTheSignatureFails() async throws {
        let bench = try await EnablerBench()
        bench.verifier.setValid(false)
        let r = await bench.enabler.enable(confirmation: "ENABLE")
        #expect(Self.error(r) == .signature)
        #expect(bench.reaperIsInstalled() == false)
        #expect(bench.tmpCopyExists() == false)
        #expect(bench.reaperConf() == .missing)
        try await Self.expectOff(bench)
    }

    @Test("reaper.conf を書けなければ reaper を消して戻す")
    func enableRollsBackWhenTheConfCannotBeWritten() async throws {
        let bench = try await EnablerBench()
        try bench.makeDirectory(at: bench.layout.reaperConf)
        let r = await bench.enabler.enable(confirmation: "ENABLE")
        guard case .failure(.reaperConfWrite) = r else {
            Issue.record("reaperConfWrite でない: \(r)")
            return
        }
        #expect(bench.reaperIsInstalled() == false)
        #expect(bench.tmpCopyExists() == false)
        try await Self.expectOff(bench)
    }

    @Test("config を書けなければ reaper.conf を戻し reaper を消す")
    func enableRollsBackWhenTheConfigIsRejected() async throws {
        let bench = try await EnablerBench()
        let before = try Data(contentsOf: bench.layout.configFile)
        try Self.blockConfig(bench)
        defer { Self.restoreConfig(bench) }
        let r = await bench.enabler.enable(confirmation: "ENABLE")
        guard case .failure(.config) = r else {
            Issue.record("config でない: \(r)")
            return
        }
        #expect(bench.reaperIsInstalled() == false)
        #expect(bench.reaperConf() == .missing)
        #expect(try Data(contentsOf: bench.layout.configFile) == before)
    }

    @Test("巻き戻しは元の reaper.conf の内容に戻す")
    func enableRestoresTheOldConfOnRollback() async throws {
        let bench = try await EnablerBench()
        let original = Data("SCHEMA=1\nDELETE_SOURCE_AUDIO=false\nVOLUMES_ROOT=/x\n".utf8)
        try bench.scene.writeReaperConfRaw(original)
        try Self.blockConfig(bench)
        defer { Self.restoreConfig(bench) }
        _ = await bench.enabler.enable(confirmation: "ENABLE")
        #expect(try Data(contentsOf: bench.layout.reaperConf) == original)
    }

    @Test("元から在った reaper は巻き戻しで消さない")
    func enableKeepsAnExistingReaperOnRollback() async throws {
        let bench = try await EnablerBench()
        try bench.scene.installReaperStub()
        try Self.blockConfig(bench)
        defer { Self.restoreConfig(bench) }
        let r = await bench.enabler.enable(confirmation: "ENABLE")
        guard case .failure(.config) = r else {
            Issue.record("config でない: \(r)")
            return
        }
        #expect(bench.reaperIsInstalled() == true)
    }

    @Test("設定エラー中は有効化しない")
    func enableRefusesWhenTheConfigIsNotLoaded() async throws {
        let bench = try await EnablerBench()
        try Data("{".utf8).write(to: bench.layout.configFile)
        _ = await bench.store.load()
        let r = await bench.enabler.enable(confirmation: "ENABLE")
        #expect(Self.error(r) == .configNotLoaded)
        #expect(bench.reaperIsInstalled() == false)
        #expect(bench.reaperConf() == .missing)
        #expect(bench.verifier.verifiedURLs.isEmpty)
        #expect(try Data(contentsOf: bench.layout.configFile) == Data("{".utf8))
    }

    @Test("既存の VOLUMES_ROOT を引き継ぐ")
    func enableKeepsTheVolumesRootOfTheOldConf() async throws {
        let bench = try await EnablerBench()
        try bench.scene.writeReaperConfRaw(Data("SCHEMA=1\nDELETE_SOURCE_AUDIO=false\nVOLUMES_ROOT=/x\n".utf8))
        let r = await bench.enabler.enable(confirmation: "ENABLE")
        #expect(Self.error(r) == nil)
        #expect(bench.reaperConf() == .valid(ReaperConf(deleteSourceAudio: true, volumesRoot: "/x")))
    }

    // MARK: - 根拠 B

    @Test("根拠 B を ENABLE で有効にする")
    func enableSkippedSetsTheFlag() async throws {
        let bench = try await EnablerBench(enabled: true)
        let r = await bench.enabler.enableSkippedDeletion(confirmation: "ENABLE")
        #expect(Self.error(r) == nil)
        #expect(try #require(await bench.config()).cleanup.deleteSkippedSource == true)
        #expect(bench.logLines().contains { $0.hasSuffix(" deletion_enabled reason=skipped_source") })
    }

    @Test("ENABLE 以外では通らない")
    func enableSkippedRequiresTheExactWord() async throws {
        let bench = try await EnablerBench(enabled: true)
        let r = await bench.enabler.enableSkippedDeletion(confirmation: "y")
        #expect(Self.error(r) == .notConfirmed)
        #expect(try #require(await bench.config()).cleanup.deleteSkippedSource == false)
    }

    @Test("CV-43 削除が無効なら根拠 B にできない")
    func enableSkippedRequiresDeletionEnabled() async throws {
        let bench = try await EnablerBench()
        let r = await bench.enabler.enableSkippedDeletion(confirmation: "ENABLE")
        #expect(Self.error(r) == .config([]))
        #expect(try #require(await bench.config()).cleanup.deleteSkippedSource == false)
    }

    // MARK: - 無効化

    /// 三重ロックが外れた状態に要求を 2 件置く
    static func enabledBench() async throws -> EnablerBench {
        let bench = try await EnablerBench(enabled: true)
        try bench.placeRequest("20260912T030000Z-aaaaaaaaaaaaaaaa-000001.json")
        try bench.placeRequest("20260912T030000Z-aaaaaaaaaaaaaaaa-000002.json")
        return bench
    }

    @Test("無効化は確認なしで全部掛け直す")
    func disableTurnsEverythingBackOnWithoutAsking() async throws {
        let bench = try await Self.enabledBench()
        let failed = await bench.enabler.disable()
        #expect(failed == [])
        guard case .valid(let conf) = bench.reaperConf() else {
            Issue.record("reaper.conf が読めない")
            return
        }
        #expect(conf.deleteSourceAudio == false)
        #expect(bench.reaperIsInstalled() == false)
        try await Self.expectOff(bench)
        #expect(Self.names(in: bench.layout.queueDelete).isEmpty)
        #expect(await bench.ingest.scanNowCalls == 1)
        #expect(bench.logLines().filter { $0.contains(" INFO  deletion_disabled") }.count == 1)
        #expect(Self.count(bench, "deletion_disabled") == 1)
    }

    @Test("F-37 回帰: reaper.conf を書けなくても config は無効になる")
    func disableIsNotBlockedByItsOwnCV30() async throws {
        let bench = try await Self.enabledBench()
        // reaper.conf は true のまま読めるが、AtomicFile の tmp の位置がディレクトリなので書き換えられない
        try bench.makeDirectory(at: AtomicFile.tmpURL(for: bench.layout.reaperConf))
        let failed = await bench.enabler.disable()
        #expect(failed.contains("reaper_conf"))
        #expect(try #require(await bench.config()).cleanup.deleteSourceAudio == false)
        #expect(bench.reaperIsInstalled() == false)
        #expect(Self.names(in: bench.layout.queueDelete).isEmpty)
        #expect(await bench.ingest.scanNowCalls == 1)
    }

    @Test("途中で失敗しても残りを続ける")
    func disableContinuesAfterAFailedStage() async throws {
        let bench = try await Self.enabledBench()
        // reaper の位置を空でないディレクトリにして段 2 の unlink を失敗させる
        try bench.scene.removeReaper()
        try bench.makeDirectory(at: bench.layout.reaperExecutable.appendingPathComponent("x", isDirectory: true))
        let failed = await bench.enabler.disable()
        #expect(failed == ["remove_reaper"])
        guard case .valid(let conf) = bench.reaperConf() else {
            Issue.record("reaper.conf が読めない")
            return
        }
        #expect(conf.deleteSourceAudio == false)
        #expect(try #require(await bench.config()).cleanup.deleteSourceAudio == false)
        #expect(Self.names(in: bench.layout.queueDelete).isEmpty)
        #expect(await bench.ingest.scanNowCalls == 1)
    }

    @Test("要求を全部取り下げる（結果は残す）")
    func disableWithdrawsEveryRequest() async throws {
        let bench = try await EnablerBench(enabled: true)
        try bench.placeRequest("20260912T030000Z-aaaaaaaaaaaaaaaa-000001.json")
        try bench.placeRequest("20260912T030000Z-aaaaaaaaaaaaaaaa-000002.json")
        try bench.placeRequest("20260912T030000Z-aaaaaaaaaaaaaaaa-000003.json")
        try bench.placeRequest(".tmp.json")
        try Data("{}".utf8).write(
            to: bench.layout.queueResult.appendingPathComponent("20260912T030000Z-aaaaaaaaaaaaaaaa-000009.json"))
        _ = await bench.enabler.disable()
        #expect(Self.names(in: bench.layout.queueDelete) == [".tmp.json"])
        #expect(Self.names(in: bench.layout.queueResult) == ["20260912T030000Z-aaaaaaaaaaaaaaaa-000009.json"])
    }

    @Test("再マウントが見送られたら段の名前を返す")
    func disableReportsARefusedRemount() async throws {
        let bench = try await Self.enabledBench()
        await bench.ingest.script([.skip])
        let failed = await bench.enabler.disable()
        #expect(failed == ["remount"])
        #expect(bench.reaperIsInstalled() == false)
        try await Self.expectOff(bench)
        #expect(Self.names(in: bench.layout.queueDelete).isEmpty)
        #expect(bench.logLines().contains { $0.hasSuffix(" WARNING deletion_disabled reason=remount") })
    }

    @Test("TEST-28 何も無い状態でも成功する")
    func disableOnAFreshHomeSucceeds() async throws {
        let bench = try await EnablerBench()
        let failed = await bench.enabler.disable()
        #expect(failed == [])
        #expect(bench.reaperConf() == .valid(ReaperConf(deleteSourceAudio: false, volumesRoot: "/Volumes")))
        try await Self.expectOff(bench)
    }

    @Test("失敗した段は順番どおりに返る")
    func disableReportsTheStagesInOrder() async throws {
        let bench = try await Self.enabledBench()
        try bench.scene.removeReaperConf()
        try bench.makeDirectory(at: bench.layout.reaperConf)
        try bench.setPermissions(0o555, at: bench.layout.binDirectory)
        defer { try? bench.setPermissions(0o755, at: bench.layout.binDirectory) }
        let failed = await bench.enabler.disable()
        #expect(failed == ["reaper_conf", "remove_reaper"])
    }

    // MARK: - 段の順（消す能力に近いものから先に止める）

    @Test("無効化は reaper.conf を config より先に止める")
    func disableReportsConfBeforeConfig() async throws {
        let bench = try await Self.enabledBench()
        try bench.makeDirectory(at: AtomicFile.tmpURL(for: bench.layout.reaperConf))
        try Self.blockConfig(bench)
        defer { Self.restoreConfig(bench) }
        let failed = await bench.enabler.disable()
        #expect(failed == ["reaper_conf", "config"])
    }

    @Test("無効化は reaper の削除を config より先に行う")
    func disableReportsRemoveReaperBeforeConfig() async throws {
        let bench = try await Self.enabledBench()
        try bench.scene.removeReaper()
        try bench.makeDirectory(at: bench.layout.reaperExecutable.appendingPathComponent("x", isDirectory: true))
        try Self.blockConfig(bench)
        defer { Self.restoreConfig(bench) }
        let failed = await bench.enabler.disable()
        #expect(failed == ["remove_reaper", "config"])
    }

    /// 再マウントを促す時点で見えていた状態
    struct AtScan: Equatable, Sendable {
        var confOff = false
        var reaperGone = false
        var configOff = false
        var requestsEmpty = false
    }

    @Test("無効化の再マウントはほかの段が全部済んでから")
    func disableScansLast() async throws {
        let bench = try await Self.enabledBench()
        let seen = Mutex<AtScan?>(nil)
        let layout = bench.layout
        let scene = bench.scene
        await bench.ingest.setScanner { generation in
            var at = AtScan()
            if case .valid(let c) = ReaperConf.observe(at: layout.reaperConf) { at.confOff = !c.deleteSourceAudio }
            at.reaperGone = !FileManager.default.fileExists(atPath: layout.reaperExecutable.path(percentEncoded: false))
            let json = (try? String(contentsOf: layout.configFile, encoding: .utf8)) ?? ""
            at.configOff = json.contains("\"deleteSourceAudio\" : false")
            at.requestsEmpty = scene.requests().isEmpty
            seen.withLock { $0 = at }
            return scene.snapshot(generation: generation)
        }
        _ = await bench.enabler.disable()
        #expect(seen.withLock { $0 } == AtScan(confOff: true, reaperGone: true, configOff: true, requestsEmpty: true))
    }

    // MARK: - 直列化（actor の再入）

    @Test("有効化の途中で来た無効化は有効化の後に走る（無効化が勝つ）")
    func disableDuringEnableWins() async throws {
        let bench = try await EnablerBench()
        let store = bench.store
        let gate = DispatchSemaphore(value: 0)
        let entered = Mutex(false)
        // ConfigStore を塞ぎ、有効化を最初の await（config.current()）で止める
        let blocker = Task {
            await store.update { _ in
                entered.withLock { $0 = true }
                gate.wait()
            }
        }
        while !entered.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        let enabling = Task { await bench.enabler.enable(confirmation: "ENABLE") }
        try await Task.sleep(for: .milliseconds(200))
        let disabling = Task { await bench.enabler.disable() }
        try await Task.sleep(for: .milliseconds(200))
        gate.signal()
        _ = await blocker.value
        let enabled = await enabling.value
        let failed = await disabling.value
        #expect(Self.error(enabled) == nil)
        #expect(failed == [])
        #expect(bench.reaperConf() == .valid(ReaperConf(deleteSourceAudio: false, volumesRoot: "/Volumes")))
        #expect(bench.reaperIsInstalled() == false)
        try await Self.expectOff(bench)
    }

    // MARK: - 消す能力が残っているか

    @Test("TEST-28 何も無ければ消す能力は残っていない")
    func noRemainingCapabilityOnAFreshHome() async throws {
        let bench = try await EnablerBench()
        #expect(await bench.enabler.hasRemainingCapability() == false)
    }

    @Test("reaper.conf が有効なら消す能力が残っている")
    func confKeepsTheCapability() async throws {
        let bench = try await EnablerBench()
        try bench.scene.writeReaperConf(deleteSourceAudio: true)
        #expect(await bench.enabler.hasRemainingCapability() == true)
    }

    @Test("reaper が在れば消す能力が残っている")
    func reaperKeepsTheCapability() async throws {
        let bench = try await EnablerBench()
        try bench.scene.installReaperStub()
        #expect(await bench.enabler.hasRemainingCapability() == true)
    }

    @Test("reaper.conf が無効で reaper が無ければ残っていない")
    func disabledConfWithoutReaperHasNoCapability() async throws {
        let bench = try await EnablerBench()
        try bench.scene.writeReaperConf(deleteSourceAudio: false)
        #expect(await bench.enabler.hasRemainingCapability() == false)
    }

    @Test("舞台: 本物の reaper と既定の /Volumes は組み合わせない")
    func benchRefusesRealReaperWithoutTheSceneVolumesRoot() async {
        await #expect(throws: BenchError.self) { _ = try await EnablerBench(enabled: false, realReaper: true) }
    }
}
