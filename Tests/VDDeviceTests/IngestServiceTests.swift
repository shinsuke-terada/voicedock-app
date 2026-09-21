// IngestService の走査・snapshot・起動契機（T-15 §5.4）。volumesRoot は必ず一時ディレクトリ（<tmp>/Volumes。/Volumes に触れない）。
import Darwin
import Foundation
import Synchronization
import TestSupport
import Testing
import VDContract
import VDCore
import VDProcess
import VDStore

@testable import VDDevice

@Suite("IngestService の走査", .serialized)
struct IngestServiceTests {
    static let deviceID = "DJIMIC3"

    /// 開けるまで待たせる門（走査を途中で止めておく）
    actor Gate {
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private(set) var entered = 0

        func wait() async {
            entered += 1
            if isOpen { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            isOpen = true
            for continuation in waiting { continuation.resume() }
            waiting = []
        }
    }

    /// 最初の 1 回だけ真を返す
    final class Once: Sendable {
        private let fired = Mutex(false)
        func first() -> Bool {
            fired.withLock { value in
                defer { value = true }
                return !value
            }
        }
    }

    struct Options {
        var mountMode = "ro"
        var scanIntervalSeconds: Int? = nil
        var configMissing = false
        var outcomes: [RemountOutcome] = [.alreadyReadOnly]
        var onRemount: (@Sendable () async -> Void)? = nil
        /// 設定すると outcomes を [.remounted(newPath: <tmp>/Volumes/DJIMIC3 + この文字列)] にする（"" は同じパス）
        var remountedSuffix: String? = nil
        var readOnly = false
        /// false なら infos を空にし mountPoints とボリューム名だけ登録する（statfs が取れない）
        var observable = true
        var coexistence: Int32 = 113
        var sleeper: (any Sleeper)? = nil
        var populate = true
        var events = FakeMountEventSource()
    }

    struct Harness {
        let tmp: TempDirectory
        let fake: FakeVolume
        let layout: HomeLayout
        let store: Store
        let sink: CapturingLogSink
        let clock: FixedClock
        let recordingSleeper: RecordingSleeper
        let remounter: FakeRemounter
        let events: FakeMountEventSource
        let service: IngestService

        init(_ options: Options = Options()) throws {
            tmp = try TempDirectory()
            fake = try FakeVolume(in: tmp, deviceID: IngestServiceTests.deviceID)
            if options.populate { try DefaultDeviceTree.populate(fake) }
            layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
            try layout.createDirectories()
            clock = FixedClock(epochMillis: 1_790_000_000_000)
            let zone = ZonedTime(timeZone: try #require(TimeZone(identifier: "Asia/Tokyo")))
            store = try Store(url: layout.database, clock: clock, zone: zone)
            sink = CapturingLogSink()
            let log = AppLog(sink: sink, level: .debug, unsafeContent: false, zone: zone, clock: clock)
            var config = AppConfig.defaults(timeZone: "Asia/Tokyo")
            config.device.mountMode = options.mountMode
            if let seconds = options.scanIntervalSeconds { config.device.scanIntervalSeconds = seconds }
            let provided: AppConfig? = options.configMissing ? nil : config
            let path = fake.volumesRoot.appendingPathComponent(IngestServiceTests.deviceID, isDirectory: false)
                .path(percentEncoded: false)
            var inspector = FakeMountInspector.mounted([path], readOnly: options.readOnly)
            if !options.observable {
                inspector.infos = [:]
            }
            recordingSleeper = RecordingSleeper()
            let outcomes =
                options.remountedSuffix.map { [RemountOutcome.remounted(newPath: path + $0)] } ?? options.outcomes
            remounter = FakeRemounter(outcomes: outcomes, onRemount: options.onRemount)
            events = options.events
            let deps = IngestDependencies(
                layout: layout, configProvider: { provided }, store: store, inspector: inspector,
                remounter: remounter, mountEvents: events, reader: DeviceReader(),
                coexistence: CoexistenceGuard(
                    runner: ScriptedProcessRunner(results: [ScriptedProcessRunner.exited(options.coexistence)]),
                    uid: 501),
                clock: clock, sleeper: options.sleeper ?? recordingSleeper, zone: zone, log: log,
                volumesRoot: fake.volumesRoot.path(percentEncoded: false))
            service = IngestService(deps: deps)
        }

        /// <tmp>/Volumes/DJIMIC3（末尾の / なし）
        var mountPath: String {
            fake.volumesRoot.appendingPathComponent(IngestServiceTests.deviceID, isDirectory: false)
                .path(percentEncoded: false)
        }

        /// inbox の下の通常ファイル（. 始まりを除く）の数
        func inboxFileCount() -> Int {
            guard let enumerator = FileManager.default.enumerator(at: layout.inbox, includingPropertiesForKeys: nil)
            else { return 0 }
            var count = 0
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                if values?.isRegularFile == true && !url.lastPathComponent.hasPrefix(".") { count += 1 }
            }
            return count
        }

        func lines(containing text: String) -> [String] { sink.lines.filter { $0.contains(text) } }

        func observation() async -> DeviceObservation? {
            await service.latestSnapshot()?.devices[IngestServiceTests.deviceID]
        }

        /// FakeVolume を別名へ rename して「無」にする／戻して「在」にする（一時ディレクトリの中だけ）
        func setPresent(_ present: Bool) throws {
            let away = tmp.url.appendingPathComponent("DJIMIC3.away", isDirectory: true)
            let manager = FileManager.default
            if present {
                if manager.fileExists(atPath: away.path(percentEncoded: false)) {
                    try manager.moveItem(at: away, to: fake.root)
                }
            } else {
                try manager.moveItem(at: fake.root, to: away)
            }
        }
    }

    /// condition が真になるまで 10 ms ごとに確かめる（5 秒で打ち切り）
    static func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<500 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    /// generation の snapshot が公開され、走査のループが止まっている
    static func settled(_ service: IngestService, generation: UInt64) async -> Bool {
        let current = await service.latestSnapshot()?.generation
        let scanning = await service.activity().scanning
        return current == generation && !scanning
    }

    /// stop() の後、走っている走査が終わるまで待つ（一時ディレクトリを消す前の後始末）
    static func stopAndDrain(_ service: IngestService) async {
        await service.stop()
        _ = await waitUntil { await !service.activity().scanning }
    }

    @Test("最初の走査で generation 1 の snapshot を公開する")
    func firstScanPublishesGenerationOne() async throws {
        let h = try Harness()
        #expect(await h.service.scanNow() == 1)
        #expect(await h.observation()?.relpaths.count == 4)
        #expect(h.inboxFileCount() == 2)
    }

    @Test("CE device.mountMode rw なら再マウントしない")
    func rwModeDoesNotRemount() async throws {
        let ro = try Harness()
        _ = await ro.service.scanNow()
        #expect(await ro.remounter.calls.count == 1)
        var options = Options()
        options.mountMode = "rw"
        let rw = try Harness(options)
        #expect(await rw.service.scanNow() == 1)
        #expect(await rw.remounter.calls.isEmpty)
    }

    @Test("再マウントが失敗しても観測が ro なら readOnly は真（DEL-31）")
    func readOnlyIsObservedNotInferredFromFailure() async throws {
        var options = Options()
        options.outcomes = [.failed(reason: "unmount_failed")]
        options.readOnly = true
        let h = try Harness(options)
        _ = await h.service.scanNow()
        #expect(await h.observation()?.readOnly == true)
        #expect(h.sink.lines.contains { $0.hasSuffix("WARNING remount_failed name=DJIMIC3 reason=unmount_failed") })
    }

    @Test("再マウントが成功しても観測が rw なら偽で still_writable")
    func readOnlyIsObservedNotInferredFromSuccess() async throws {
        var options = Options()
        options.remountedSuffix = ""
        options.readOnly = false
        let h = try Harness(options)
        _ = await h.service.scanNow()
        #expect(await h.observation()?.readOnly == false)
        #expect(h.sink.lines.contains { $0.hasSuffix("WARNING remount_failed name=DJIMIC3 reason=still_writable") })
    }

    @Test("rw でも観測する")
    func rwModeStillObserves() async throws {
        var options = Options()
        options.mountMode = "rw"
        options.readOnly = true
        let h = try Harness(options)
        _ = await h.service.scanNow()
        #expect(await h.observation()?.readOnly == true)
    }

    @Test("statfs が取れなければ readOnly は nil（偽にしない）")
    func unobservableReadOnlyIsNil() async throws {
        var options = Options()
        options.observable = false
        let h = try Harness(options)
        #expect(await h.service.scanNow() == 1)
        let observation = try #require(await h.observation())
        #expect(observation.readOnly == nil)
        #expect(observation.freeBytes == nil)
    }

    @Test("再マウントに失敗しても取り込みは続ける（記録の保護）")
    func remountFailureStillIngests() async throws {
        var options = Options()
        options.outcomes = [.failed(reason: "mount_failed")]
        let h = try Harness(options)
        _ = await h.service.scanNow()
        #expect(h.inboxFileCount() == 2)
    }

    @Test("0 台なら devices が空（DEL-32）")
    func zeroDevicesIsEmptyNotUnknown() async throws {
        let h = try Harness()
        try h.setPresent(false)
        #expect(await h.service.scanNow() == 1)
        let snapshot = try #require(await h.service.latestSnapshot())
        #expect(snapshot.generation == 1)
        #expect(snapshot.devices == [:])
        #expect(snapshot.unavailable == [:])
    }

    @Test("録音 0 件のデバイスも空の観測として載せる（DEV-19）")
    func emptyDeviceIsObserved() async throws {
        var options = Options()
        options.populate = false
        let h = try Harness(options)
        try h.fake.addDirectory("TX_MIC001_20260912_120950")
        _ = await h.service.scanNow()
        #expect(await h.observation()?.relpaths == [])
    }

    @Test("connectEpoch は 0 台（か前回なし）→ 1 台以上のたびに +1")
    func connectEpochRisesOnZeroToSome() async throws {
        let h = try Harness()
        var epochs: [UInt64] = []
        for present in [true, true, false, true] {
            try h.setPresent(present)
            _ = await h.service.scanNow()
            epochs.append(try #require(await h.service.latestSnapshot()).connectEpoch)
        }
        #expect(epochs == [1, 1, 1, 2])
    }

    @Test("最初が 0 台なら上がらず、次に 1 台で上がる")
    func connectEpochStartsAfterAnEmptyScan() async throws {
        let h = try Harness()
        var epochs: [UInt64] = []
        for present in [false, true] {
            try h.setPresent(present)
            _ = await h.service.scanNow()
            epochs.append(try #require(await h.service.latestSnapshot()).connectEpoch)
        }
        #expect(epochs == [0, 1])
    }

    @Test("見送った走査は前回の観測を変えない")
    func skippedScanDoesNotChangeEpoch() async throws {
        let h = try Harness()
        #expect(await h.service.scanNow() == 1)
        let first = try #require(await h.service.latestSnapshot())
        let held = try #require(FileLock.tryAcquire(url: h.layout.reaperLock))
        #expect(await h.service.scanNow() == nil)
        #expect(await h.service.latestSnapshot() == first)
        held.release()
        #expect(await h.service.scanNow() == 2)
        let third = try #require(await h.service.latestSnapshot())
        #expect([first.connectEpoch, third.connectEpoch] == [1, 1])
    }

    @Test("再マウント中の通知で途中の 0 台の snapshot を作らない")
    func noZeroDeviceSnapshotDuringRemount() async throws {
        let events = FakeMountEventSource()
        let once = Once()
        var options = Options()
        options.events = events
        options.sleeper = SuspendingSleeper()
        // アンマウントとマウントの 2 通知。届くまで再マウントの中で待つ
        options.onRemount = {
            guard once.first() else { return }
            events.send()
            events.send()
            try? await Task.sleep(for: .milliseconds(300))
        }
        let h = try Harness(options)
        await h.service.start()
        let settled = await Self.waitUntil {
            await Self.settled(h.service, generation: 2)
        }
        try? await Task.sleep(for: .milliseconds(200))
        await Self.stopAndDrain(h.service)
        #expect(settled)
        #expect(await h.service.latestSnapshot()?.generation == 2)
        let completed = h.lines(containing: "scan_completed")
        #expect(completed.count == 2)
        #expect(completed.allSatisfy { $0.contains("scan_completed devices=1 ") })
    }

    @Test("走査中に呼んだ scanNow は次に始まる走査を待つ")
    func scanNowWaitsForAScanStartedAfterTheCall() async throws {
        let gate = Gate()
        var options = Options()
        options.onRemount = { await gate.wait() }
        let h = try Harness(options)
        let service = h.service
        let first = Task { await service.scanNow() }
        #expect(await Self.waitUntil { await gate.entered == 1 })
        let second = Task { await service.scanNow() }
        #expect(await Self.waitUntil { await service.waiters.count == 2 })
        await gate.open()
        #expect(await first.value == 1)
        #expect(await second.value == 2)
    }

    @Test("reaper.lock が取れなければ 130 回試して見送る")
    func lockBusyMakesScanNowNil() async throws {
        let h = try Harness()
        let held = try #require(FileLock.tryAcquire(url: h.layout.reaperLock))
        #expect(await h.service.scanNow() == nil)
        #expect(h.recordingSleeper.recorded == Array(repeating: 1, count: 129))
        #expect(await h.service.latestSnapshot() == nil)
        #expect(h.inboxFileCount() == 0)
        held.release()
    }

    @Test("走査が終わればロックを外す")
    func lockIsReleasedAfterScan() async throws {
        let h = try Harness()
        #expect(await h.service.scanNow() == 1)
        let lock = FileLock.tryAcquire(url: h.layout.reaperLock)
        #expect(lock != nil)
        lock?.release()
    }

    @Test("voicedock の Helper が登録されていれば何もしない。ログは入ったときだけ")
    func coexistenceBlocksAndLogsOnce() async throws {
        var options = Options()
        options.coexistence = 0
        let h = try Harness(options)
        #expect(await h.service.scanNow() == nil)
        #expect(await h.service.scanNow() == nil)
        #expect(await h.service.state() == .coexistenceBlocked)
        #expect(h.lines(containing: "coexistence_blocked").count == 1)
        #expect(h.inboxFileCount() == 0)
    }

    @Test("設定エラー中は走査しない")
    func configErrorDisables() async throws {
        var options = Options()
        options.configMissing = true
        let h = try Harness(options)
        #expect(await h.service.scanNow() == nil)
        #expect(await h.service.state() == .disabled)
    }

    @Test("再マウントでパスに ` 1` が付けば取り込まず mount_name_mismatch")
    func nameMismatchAfterRemountIsUnavailable() async throws {
        var options = Options()
        options.remountedSuffix = " 1"
        let h = try Harness(options)
        _ = await h.service.scanNow()
        #expect(await h.remounter.calls.map(\.path) == [h.mountPath])
        let snapshot = try #require(await h.service.latestSnapshot())
        #expect(snapshot.devices["DJIMIC3"] == nil)
        #expect(snapshot.unavailable["DJIMIC3"] == "mount_name_mismatch")
        #expect(h.inboxFileCount() == 0)
    }

    @Test("列挙に失敗したサブディレクトリがあればそのデバイスを観測に載せない")
    func incompleteListingIsNotObserved() async throws {
        let h = try Harness()
        let folder = h.fake.url("TX_MIC002_20260913_090000").path(percentEncoded: false)
        #expect(chmod(folder, 0o000) == 0)
        defer { _ = chmod(folder, 0o755) }
        _ = await h.service.scanNow()
        let snapshot = try #require(await h.service.latestSnapshot())
        #expect(snapshot.devices["DJIMIC3"] == nil)
        #expect(snapshot.unavailable["DJIMIC3"] == "not_listable")
    }

    @Test("not_listable の errno を snapshot に残す")
    func notListableCarriesErrno() async throws {
        let h = try Harness()
        let root = h.fake.root.path(percentEncoded: false)
        #expect(chmod(root, 0o000) == 0)
        defer { _ = chmod(root, 0o755) }
        _ = await h.service.scanNow()
        let snapshot = try #require(await h.service.latestSnapshot())
        #expect(snapshot.notListableErrno["DJIMIC3"] == EACCES)
        #expect(snapshot.unavailable["DJIMIC3"] == "not_listable")
    }

    @Test("利用者の操作が要る理由は変わったときだけ WARNING")
    func unavailableWarnsOnlyOnChange() async throws {
        let h = try Harness()
        let root = h.fake.root.path(percentEncoded: false)
        #expect(chmod(root, 0o000) == 0)
        defer { _ = chmod(root, 0o755) }
        _ = await h.service.scanNow()
        let afterFirst = h.lines(containing: "volume_skipped")
        #expect(afterFirst.count == 1)
        #expect(
            afterFirst.allSatisfy { $0.hasSuffix("WARNING volume_skipped name=DJIMIC3 reason=not_listable detail=13") })
        _ = await h.service.scanNow()
        let second = h.lines(containing: "volume_skipped").dropFirst(afterFirst.count)
        #expect(second.count == 1)
        #expect(second.allSatisfy { $0.hasSuffix("DEBUG volume_skipped name=DJIMIC3 reason=not_listable detail=13") })
    }

    @Test("scan_completed はコピーがあれば INFO、無ければ DEBUG")
    func scanCompletedLevels() async throws {
        let h = try Harness()
        _ = await h.service.scanNow()
        _ = await h.service.scanNow()
        let lines = h.lines(containing: "scan_completed")
        try #require(lines.count == 2)
        #expect(lines[0].contains("INFO  scan_completed devices=1 copied=2 elapsed_s="))
        #expect(lines[1].contains("DEBUG scan_completed devices=1 copied=0 elapsed_s="))
    }

    @Test("進捗を IngestActivity に出す")
    func activityTracksCopies() async throws {
        let h = try Harness()
        _ = await h.service.scanNow()
        let activity = await h.service.activity()
        #expect(activity.copied == 2)
        #expect(activity.total == 2)
        #expect(activity.lastActivityAt == Instant(epochMillis: 1_790_000_000_000))
        #expect(activity.lastActivityAt == h.clock.now())
        #expect(activity.scanning == false)
    }

    @Test("公開のたびに updates に流れる")
    func updatesYieldOnPublish() async throws {
        let h = try Harness()
        let updates = await h.service.updates()
        #expect(await h.service.scanNow() == 1)
        var iterator = updates.makeAsyncIterator()
        let received: Void? = await iterator.next()
        #expect(received != nil)
    }

    @Test("CE device.scanIntervalSeconds が周期の待ちになる")
    func ceScanIntervalSeconds() async throws {
        var options = Options()
        options.scanIntervalSeconds = 600
        let h = try Harness(options)
        await h.service.start()
        #expect(await Self.waitUntil { !h.recordingSleeper.recorded.isEmpty })
        await Self.stopAndDrain(h.service)
        #expect(h.recordingSleeper.recorded.first == 600)
        #expect(h.recordingSleeper.recorded.allSatisfy { $0 == 600 })

        let d = try Harness()
        await d.service.start()
        #expect(await Self.waitUntil { !d.recordingSleeper.recorded.isEmpty })
        await Self.stopAndDrain(d.service)
        #expect(d.recordingSleeper.recorded.first == 300)
    }

    @Test("マウント通知で走査する")
    func mountEventTriggersScan() async throws {
        var options = Options()
        options.sleeper = SuspendingSleeper()
        let h = try Harness(options)
        let service = h.service
        await service.start()
        #expect(
            await Self.waitUntil {
                await Self.settled(service, generation: 1)
            })
        let updates = await service.updates()
        h.events.send()
        let reached = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in updates where await service.latestSnapshot()?.generation == 2 { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        await Self.stopAndDrain(service)
        #expect(reached)
    }

    @Test("stop で待っている scanNow に nil を返す")
    func stopResolvesWaiters() async throws {
        let gate = Gate()
        var options = Options()
        options.onRemount = { await gate.wait() }
        let h = try Harness(options)
        let service = h.service
        let first = Task { await service.scanNow() }
        #expect(await Self.waitUntil { await gate.entered == 1 })
        let waiting = Task { await service.scanNow() }
        #expect(await Self.waitUntil { await service.waiters.count == 2 })
        await service.stop()
        #expect(await waiting.value == nil)
        #expect(await first.value == nil)
        await gate.open()
        _ = await Self.waitUntil { await !service.activity().scanning }
    }

    @Test("volumesRoot 自体を列挙できなければ 0 台として公開しない（DEL-32）")
    func unlistableVolumesRootIsNotPublished() async throws {
        let h = try Harness()
        #expect(await h.service.scanNow() == 1)
        let root = h.fake.volumesRoot.path(percentEncoded: false)
        #expect(chmod(root, 0o000) == 0)
        defer { _ = chmod(root, 0o755) }
        #expect(await h.service.scanNow() == nil)
        let snapshot = try #require(await h.service.latestSnapshot())
        #expect(snapshot.generation == 1)
        #expect(snapshot.devices["DJIMIC3"] != nil)
    }
}
