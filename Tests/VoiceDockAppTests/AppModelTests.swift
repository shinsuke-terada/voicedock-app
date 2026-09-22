// AppModel（UI が見る唯一の値）のテスト（T-30 §5.3）。ビューは作らない。
import Foundation
import Observation
import Synchronization
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDLLM
import VDModels
import VDPipeline
import VDProcess
import VDStore

@testable import VoiceDockApp

@MainActor
@Suite("AppModel")
struct AppModelTests {
    static let fixed = Instant(epochMillis: 1_756_000_000_000)
    static let layout = HomeLayout(root: URL(fileURLWithPath: "/tmp/voicedock-t30-layout", isDirectory: true))

    /// 設定が読めていて、それ以外は空の観測
    static func present() -> AppSnapshot {
        var s = AppSnapshot(now: fixed)
        s.configPresent = true
        return s
    }

    /// quit が呼ばれた回数（@MainActor のクロージャから数える）
    final class QuitCounter {
        var count = 0
    }

    static func makeModel(
        _ fake: FakeServices, finder: FakeFinder = FakeFinder(), sleeper: any Sleeper = RecordingSleeper(),
        quits: QuitCounter = QuitCounter()
    ) -> AppModel {
        AppModel(
            services: fake, openFinder: finder, layout: layout, catalog: TestCatalogs.minimal,
            chooser: FakeFolderChooser(nil), fileChooser: FakeFileChooser(nil), presentModal: { $0() },
            sleeper: sleeper, now: fixed, quit: { quits.count += 1 })
    }

    /// 条件が立つまで主アクターを譲る（上限つき。立たなければ偽）
    static func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<5_000 {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    @Test("refresh は観測をそのまま写す")
    func refreshCopiesTheSnapshot() async {
        var s = Self.present()
        s.timeZone = "Asia/Tokyo"
        s.backlog = BacklogCounts(count: 6, seconds: 11_520, unknownDuration: 1)
        s.vaultPath = "/tmp/vault"
        let fake = FakeServices(s)
        let model = Self.makeModel(fake)
        await model.refresh()
        #expect(model.snapshot == s)
    }

    @Test("前回の最終接続を read に渡す")
    func refreshPassesLastConnectedBack() async {
        let t = Instant(epochMillis: 1_755_999_000_000)
        var s = Self.present()
        s.lastConnectedAt = t
        let fake = FakeServices(s)
        let model = Self.makeModel(fake)
        await model.refresh()
        await model.refresh()
        #expect(fake.lastConnectedSeen == [nil, t])
    }

    @Test("アイコンが変わらなければ通知しない")
    func iconChangesOnlyWhenIconChanges() async {
        let s = Self.present()
        let fake = FakeServices(s)
        let model = Self.makeModel(fake)
        let changes = model.iconChanges
        await model.refresh()
        // 同じ観測での 2 回目は snapshot を書き換えない（SwiftUI の再描画を起こさない）
        let observed = Mutex(false)
        withObservationTracking {
            _ = model.snapshot
        } onChange: {
            observed.withLock { $0 = true }
        }
        await model.refresh()
        #expect(observed.withLock { $0 } == false)
        var trashOn = s
        trashOn.deletionEnabled = true
        fake.set(trashOn)
        await model.refresh()
        model.stop()
        var count = 0
        for await _ in changes { count += 1 }
        #expect(count == 1)
    }

    @Test("削除が有効なら trash を常時出す")
    func showsTrashFollowsDeletionEnabled() async {
        var s = Self.present()
        s.deletionEnabled = true
        let fake = FakeServices(s)
        let model = Self.makeModel(fake)
        await model.refresh()
        #expect(model.showsTrash == true)
    }

    @Test("要対応が立てばアイコンが変わる")
    func iconIsAttentionWhenFlagged() async {
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake)
        await model.refresh()
        #expect(model.iconState == .idle)
        model.setAttentionForTesting(true)
        #expect(model.iconState == .attention)
    }

    @Test("パネルが開いている間だけ 1 秒周期")
    func panelOpenSwitchesToFastInterval() async {
        let fake = FakeServices(Self.present())
        let sleeper = RecordingSleeper()
        let model = Self.makeModel(fake, sleeper: sleeper)
        model.start()
        #expect(await Self.waitUntil { sleeper.recorded.contains(30) })
        #expect(!sleeper.recorded.contains(1))
        model.panelDidOpen()
        #expect(await Self.waitUntil { sleeper.recorded.last == 1 })
        model.panelDidClose()
        #expect(await Self.waitUntil { sleeper.recorded.last == 30 })
        model.stop()
    }

    @Test("閉じた 30 秒の眠りの途中で開くと、すぐ読み直して 1 秒の眠りに切り替わる")
    func panelOpenWakesTheSlowSleep() async {
        let fake = FakeServices(Self.present())
        let sleeper = SuspendingRecordingSleeper()
        let model = Self.makeModel(fake, sleeper: sleeper)
        model.start()
        #expect(await Self.waitUntil { sleeper.recorded == [30] })
        let readsBeforeOpen = fake.readCount
        model.panelDidOpen()
        #expect(await Self.waitUntil { sleeper.recorded == [30, 1] })
        #expect(fake.readCount == readsBeforeOpen + 1)
        model.stop()
    }

    @Test("閉じたら『読み直しました』を消す")
    func panelCloseClearsReloadResult() async {
        let fake = FakeServices(Self.present())
        fake.setReload(.valid(AppConfig.defaults(timeZone: "Asia/Tokyo")))
        let model = Self.makeModel(fake)
        model.panelDidOpen()
        await model.reloadConfig()
        #expect(model.reloadResult == .ok)
        model.panelDidClose()
        #expect(model.reloadResult == nil)
    }

    @Test("再試行は Worker に渡して読み直す")
    func requeueManualCallsWorkerAndRefreshes() async {
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake)
        let before = fake.readCount
        await model.requeueManual()
        #expect(fake.requeueCount == 1)
        #expect(fake.readCount == before + 1)
    }

    @Test("読み直しが通れば ok")
    func reloadConfigOK() async {
        let fake = FakeServices(Self.present())
        fake.setReload(.valid(AppConfig.defaults(timeZone: "Asia/Tokyo")))
        let model = Self.makeModel(fake)
        await model.reloadConfig()
        #expect(model.reloadResult == .ok)
        #expect(fake.reloadCount == 1)
    }

    @Test("違反はそのまま持つ")
    func reloadConfigInvalidKeepsViolations() async {
        let v1 = ConfigViolation(rule: "CV-01", code: .configInvalidValue, keyPath: "timeZone", message: "a")
        let v2 = ConfigViolation(rule: "CV-41", code: .configInvalidValue, keyPath: "vault.marker", message: "b")
        let fake = FakeServices(Self.present())
        fake.setReload(.invalid([v1, v2]))
        let model = Self.makeModel(fake)
        await model.reloadConfig()
        #expect(model.reloadResult == .invalid([v1, v2]))
    }

    @Test("Finder に渡す URL は HomeLayout から取る")
    func revealOpensFinderWithTheRightURL() {
        let finder = FakeFinder()
        let model = Self.makeModel(FakeServices(Self.present()), finder: finder)
        model.revealConfigInFinder()
        model.revealLogsInFinder()
        #expect(
            finder.revealed == [
                URL(fileURLWithPath: "/tmp/voicedock-t30-layout/config.json"),
                URL(fileURLWithPath: "/tmp/voicedock-t30-layout/logs/app.log"),
            ])
    }

    @Test("終了はハンドラを呼ぶだけ")
    func quitCallsTheHandler() {
        let quits = QuitCounter()
        let model = Self.makeModel(FakeServices(Self.present()), quits: quits)
        model.quit()
        #expect(quits.count == 1)
    }

    @Test("走査の通知で読み直す")
    func startRefreshesOnIngestUpdate() async {
        let fake = FakeServices(Self.present())
        // 周期の眠りは戻らない（通知でだけ読み直すことを見る）
        let model = Self.makeModel(fake, sleeper: SuspendingSleeper())
        model.start()
        #expect(await Self.waitUntil { fake.readCount == 1 && fake.subscriberCount == 1 })
        fake.push()
        #expect(await Self.waitUntil { fake.readCount == 2 })
        model.stop()
    }

    @Test("stop で周期を止める")
    func stopCancelsTheLoop() async {
        let fake = FakeServices(Self.present())
        let clock = FixedClock(now: Self.fixed)
        let model = Self.makeModel(fake, sleeper: RecordingSleeper(clock: clock))
        model.start()
        #expect(await Self.waitUntil { fake.readCount >= 2 })
        model.stop()
        for _ in 0..<50 { await Task.yield() }
        let after = fake.readCount
        clock.advance(seconds: 3600)
        for _ in 0..<200 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(fake.readCount == after)
    }

    @Test("TEST-28 何も無い観測でも落ちない")
    func emptyServicesProduceIdlePanel() async {
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake)
        await model.refresh()
        #expect(model.statusLine == "待機中")
        #expect(model.iconState == .idle)
        #expect(model.showsTrash == false)
        #expect(model.backlogLine == "未処理なし")
    }

    @Test("DB が無ければ未処理は全 0（LiveServices は DB を作らない）")
    func bootWithoutDatabaseShowsZero() async throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
        let clock = FixedClock(now: Self.fixed)
        let zone = ZonedTime(fixedOffsetSeconds: 0)
        let log = AppLog(sink: CapturingLogSink(), level: .debug, unsafeContent: false, zone: zone, clock: clock)
        let paths = AppPaths(resources: tmp.url, helpers: tmp.url)
        let catalog = TestCatalogs.minimal
        let config = ConfigStore(layout: layout, catalog: catalog, log: log, observeReaperConf: { .missing })
        // Store は layout.database とは別の場所に開く（layout.database は無いまま）
        let store = try Store(
            url: tmp.url.appendingPathComponent("elsewhere.sqlite", isDirectory: false), clock: clock, zone: zone)
        let runner = ProcessRunner()
        let llama = LlamaServerSupervisor(
            runner: runner, paths: paths, layout: layout, clock: clock, sleeper: RecordingSleeper(), log: log,
            factory: EphemeralSessionFactory())
        let volumes = tmp.url.appendingPathComponent("Volumes", isDirectory: true)
        let ingest = IngestService(
            deps: IngestDependencies(
                layout: layout, configProvider: { await config.current() }, store: store,
                inspector: FakeMountInspector(), remounter: FakeRemounter(outcomes: []),
                mountEvents: FakeMountEventSource(), reader: DeviceReader(),
                clock: clock, sleeper: RecordingSleeper(), zone: zone, log: log,
                volumesRoot: volumes.path(percentEncoded: false)))
        let worker = Worker(
            deps: WorkerDependencies(
                layout: layout, paths: paths, store: store, config: config, ingest: ingest, runner: runner,
                llama: llama,
                chatTransportFactory: { handle, cfg in
                    LoopbackChatTransport(
                        endpoint: handle.endpoint, apiKey: handle.apiKey, modelID: handle.modelID, config: cfg,
                        factory: EphemeralSessionFactory())
                },
                clock: clock, sleeper: RecordingSleeper(), log: log, license: AlwaysAllowLicenseGate(),
                catalog: catalog, physicalMemoryBytes: 16 * 1024 * 1024 * 1024))
        let downloader = ModelDownloader(
            layout: layout, factory: EphemeralDownloadSessionFactory(), log: log, hashChunkBytes: 1_048_576)
        let models = ModelManager(
            layout: layout, catalog: catalog, downloader: downloader, cache: ModelVerificationCache(), log: log,
            hashChunkBytes: 1_048_576)
        let context = AppContext(
            layout: layout, paths: paths, clock: clock, log: log, catalog: catalog, config: config, store: store,
            runner: runner, llama: llama, ingest: ingest, worker: worker, models: models, downloader: downloader,
            loginItem: SystemLoginItem(), uiState: UIStateStore(url: layout.uiState),
            physicalMemoryBytes: 16 * 1024 * 1024 * 1024)
        let services = LiveServices(context: context)

        let s = await services.read(lastConnectedAt: nil)

        #expect(s.backlog == BacklogCounts(count: 0, seconds: 0, unknownDuration: 0))
        #expect(s.configPresent == false)
        #expect(s.device == nil)
        #expect(s.lastConnectedAt == nil)
        #expect(!FileManager.default.fileExists(atPath: layout.database.path(percentEncoded: false)))
        let model = AppModel(
            services: services, openFinder: FakeFinder(), layout: layout, catalog: catalog,
            chooser: FakeFolderChooser(nil), fileChooser: FakeFileChooser(nil), presentModal: { $0() },
            sleeper: RecordingSleeper(), now: Self.fixed, quit: {})
        await model.refresh()
        #expect(model.backlogLine == "未処理なし")
    }
}

/// 待ち秒を記録し、止められるまで戻らない Sleeper（周期の眠りの途中で起こせることを見る）。
final class SuspendingRecordingSleeper: Sleeper {
    private let seconds = Mutex<[Int]>([])

    var recorded: [Int] { seconds.withLock { $0 } }

    func sleep(seconds value: Int) async throws {
        seconds.withLock { $0.append(value) }
        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    }
}
