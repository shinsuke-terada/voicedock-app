// E2E-17 に対応する単体（無効化の後は削除の要求が書かれない。PLAN 付録 B.3。T-40 §6.4）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDStore

@testable import VDPipeline

@Suite("E2E-17 の単体: 無効化で以後削除されない", .serialized)
struct DisableStopsDeletionTests {
    /// 今の舞台の設定で削除段を 1 回回す（DeletionDependencies は毎回新しく作る）
    static func runStage(_ bench: EnablerBench) async {
        let stage = SessionDeletionStage(deps: bench.scene.deletionDependencies(ingest: bench.ingest))
        await stage.deleteSourcesIfSafe(sessionKey: bench.scene.sessionKey)
    }

    /// 本物の reaper を置いた有効な舞台で削除段を 1 回回し、要求が 1 件書かれたことを確かめる（正の対照）
    static func enabledAndRequested() async throws -> EnablerBench {
        let bench = try await EnablerBench(enabled: true, realReaper: true)
        await runStage(bench)
        #expect(bench.scene.requests().count == 1)
        return bench
    }

    /// ConfigStore の今の設定を舞台に写す（新しい DeletionDependencies はこれを読む）
    static func syncConfig(_ bench: EnablerBench) async throws {
        let c = try #require(await bench.config())
        bench.scene.updateConfig { $0 = c }
    }

    @Test("E2E-17 無効化の後は要求が書かれない")
    func e2e17DisableStopsFurtherRequests() async throws {
        let bench = try await EnablerBench(enabled: true, realReaper: true)
        #expect(await bench.scene.locks.readiness(config: bench.scene.config) == .configured)
        await Self.runStage(bench)
        #expect(bench.scene.requests().count == 1)
        let failed = await bench.enabler.disable()
        #expect(failed == [])
        try await Self.syncConfig(bench)
        await Self.runStage(bench)
        #expect(bench.scene.requests().count == 0)
        #expect(
            await bench.scene.locks.readiness(config: bench.scene.config, useCache: false)
                == .disabled(DeletionReason.deleteSourceAudioDisabled))
        #expect(
            bench.logLines().contains {
                $0.contains(" source_delete_skipped ") && $0.hasSuffix(" reason=delete_source_audio_disabled")
            })
    }

    @Test("E2E-17 途中の要求も取り下げられる")
    func e2e17DisableWithdrawsTheRequestInFlight() async throws {
        let bench = try await Self.enabledAndRequested()
        _ = await bench.enabler.disable()
        #expect(bench.scene.requests().isEmpty)
        let part = try #require(try bench.scene.store.recording(bench.scene.partkey))
        #expect(part.deleteRequestID != nil)
    }

    @Test("E2E-17 直ちに再マウントを促す")
    func e2e17DisableRemountsAtOnce() async throws {
        let bench = try await Self.enabledAndRequested()
        _ = await bench.enabler.disable()
        #expect(await bench.ingest.scanNowCalls == 1)
    }

    @Test("E2E-17 削除モジュールが消える")
    func e2e17TheReaperIsGone() async throws {
        let bench = try await EnablerBench(enabled: true, realReaper: true)
        #expect(bench.reaperIsInstalled() == true)
        _ = await bench.enabler.disable()
        #expect(bench.reaperIsInstalled() == false)
        try await Self.syncConfig(bench)
        #expect(
            await bench.scene.locks.readiness(config: bench.scene.config, useCache: false)
                == .disabled("delete_source_audio_disabled"))
    }
}
