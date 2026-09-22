// reconcileLock1 と ConfigStore.load との配線（PLAN §6.1・F-37 の回帰。T-40 §6.2）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore

@testable import VDPipeline

@Suite("ロック 1 の修復（PLAN §6.1）")
struct ReconcileLock1Tests {
    static func cv30WarningCount(_ bench: EnablerBench) -> Int {
        bench.logLines().filter { $0.contains(" config_warning rule=CV-30 ") }.count
    }

    static func offConf(_ volumesRoot: String) -> ReaperConfObservation {
        .valid(ReaperConf(deleteSourceAudio: false, volumesRoot: volumesRoot))
    }

    @Test("reaper.conf を無効側に揃えて true")
    func reconcileTurnsTheConfOff() async throws {
        let bench = try await EnablerBench(enabled: true)
        try bench.placeRequest("20260912T030000Z-aaaaaaaaaaaaaaaa-000001.json")
        let configBefore = try Data(contentsOf: bench.layout.configFile)
        let ok = await bench.enabler.reconcileLock1()
        #expect(ok == true)
        #expect(bench.reaperConf() == Self.offConf(bench.volumesRootPath))
        #expect(try Data(contentsOf: bench.layout.configFile) == configBefore)
        #expect(bench.reaperIsInstalled() == true)
        #expect(bench.scene.requests().count == 1)
    }

    @Test("VOLUMES_ROOT を消さない")
    func reconcileKeepsTheVolumesRoot() async throws {
        let bench = try await EnablerBench(enabled: true)
        _ = await bench.enabler.reconcileLock1()
        guard case .valid(let conf) = bench.reaperConf() else {
            Issue.record("reaper.conf が読めない")
            return
        }
        #expect(conf.volumesRoot == bench.volumesRootPath)
        #expect(conf.volumesRoot != "/Volumes")
    }

    @Test("conf が無くても無効側の conf を書く")
    func reconcileWritesTheConfEvenWhenItIsMissing() async throws {
        let bench = try await EnablerBench(enabled: true)
        try bench.scene.removeReaperConf()
        let ok = await bench.enabler.reconcileLock1()
        #expect(ok == true)
        #expect(bench.reaperConf() == Self.offConf("/Volumes"))
    }

    @Test("書けなければ false と config_warning")
    func reconcileFailsWhenTheConfCannotBeWritten() async throws {
        let bench = try await EnablerBench(enabled: true)
        try bench.scene.removeReaperConf()
        try bench.makeDirectory(at: bench.layout.reaperConf)
        let ok = await bench.enabler.reconcileLock1()
        #expect(ok == false)
        #expect(Self.cv30WarningCount(bench) == 1)
    }

    /// config は true/rw（舞台の既定）、reaper.conf は false
    static func halfEnabledBench() async throws -> EnablerBench {
        let bench = try await EnablerBench(enabled: true)
        try bench.scene.writeReaperConf(deleteSourceAudio: false)
        return bench
    }

    /// config は false/ro、reaper.conf は true
    static func otherDirectionBench() async throws -> EnablerBench {
        let bench = try await EnablerBench()
        try bench.scene.writeReaperConf(deleteSourceAudio: true)
        return bench
    }

    static func expectReconciled(_ bench: EnablerBench, _ result: ConfigLoadResult) {
        guard case .valid(let c) = result else {
            Issue.record("設定エラーになった: \(result)")
            return
        }
        #expect(c.cleanup.deleteSourceAudio == false)
        #expect(c.cleanup.deleteSkippedSource == false)
        #expect(c.device.mountMode == "ro")
        #expect(bench.reaperConf() == Self.offConf(bench.volumesRootPath))
        #expect(Self.cv30WarningCount(bench) == 1)
    }

    @Test("F-37 回帰: 片方だけ有効な状態が読み込みで無効側に揃う")
    func cv30IsReconciledOnLoad() async throws {
        let bench = try await Self.halfEnabledBench()
        let enabler = bench.enabler
        await bench.store.setLock1Reconciler { await enabler.reconcileLock1() }
        let result = await bench.store.load()
        Self.expectReconciled(bench, result)
    }

    @Test("逆向き（config false・conf true）も無効側に揃う")
    func cv30TheOtherDirectionIsAlsoReconciled() async throws {
        let bench = try await Self.otherDirectionBench()
        let enabler = bench.enabler
        await bench.store.setLock1Reconciler { await enabler.reconcileLock1() }
        let result = await bench.store.load()
        Self.expectReconciled(bench, result)
    }

    @Test("揃えられなければ設定エラーにする")
    func cv30BecomesAConfigErrorWhenTheConfCannotBeFixed() async throws {
        let bench = try await Self.halfEnabledBench()
        try bench.setPermissions(0o555, at: bench.layout.binDirectory)
        defer { try? bench.setPermissions(0o755, at: bench.layout.binDirectory) }
        let enabler = bench.enabler
        await bench.store.setLock1Reconciler { await enabler.reconcileLock1() }
        let result = await bench.store.load()
        guard case .invalid(let v) = result else {
            Issue.record("設定エラーにならなかった: \(result)")
            return
        }
        #expect(v.contains { $0.rule == "CV-30" })
        #expect(bench.logLines().contains { $0.contains(" config_invalid ") })
    }

    @Test("修復口を挿していなければ設定エラーのまま（対照）")
    func loadWithoutAReconcilerIsAConfigError() async throws {
        let bench = try await Self.halfEnabledBench()
        let result = await bench.store.load()
        guard case .invalid(let v) = result else {
            Issue.record("設定エラーにならなかった: \(result)")
            return
        }
        #expect(v.contains { $0.rule == "CV-30" })
    }
}
