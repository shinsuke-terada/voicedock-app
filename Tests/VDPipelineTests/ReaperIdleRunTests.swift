// reaper が処理しない要求が残る間の空回りを止める（PLAN §8.9.6。F-79・issue #118 の B3）。
// 起動は要求の宛先のデバイスが書き込み可能なときだけ。何も処理されなかった回は走査しない（走査の公開が Worker をすぐに起こすため）。
// reaper は偽物だけ（ScriptedProcessRunner と、その上で要求と結果のファイルを動かす ActingReaperRunner）。/Volumes には触れない。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDProcess
import VDStore

@testable import VDPipeline

/// reaper の偽物。記録と結果は inner（ScriptedProcessRunner）に任せ、`--home` の起動のときだけ act を行う
/// （要求を消す・結果を書く = reaper が処理した姿）。act の失敗は actFailures に記録する（テストが空であることを確かめる）。
actor ActingReaperRunner: ProcessRunning {
    let inner: ScriptedProcessRunner
    private let act: @Sendable () throws -> Void
    private(set) var actFailures: [String] = []

    init(inner: ScriptedProcessRunner, act: @escaping @Sendable () throws -> Void) {
        self.inner = inner
        self.act = act
    }

    func run(_ spec: ProcessSpec, timeout: Duration) async -> ProcessResult {
        let result = await inner.run(spec, timeout: timeout)
        if spec.arguments.first == "--home" {
            do {
                try act()
            } catch {
                actFailures.append(String(describing: error))
            }
        }
        return result
    }

    func spawn(_ spec: ProcessSpec) async throws(SpawnError) -> RunningProcess {
        try await inner.spawn(spec)
    }
}

/// ScriptedIngest に委ね、state() だけを差し替える IngestPort（ScriptedIngest の state() は常に .idle）。
actor StatefulIngest: IngestPort {
    let inner: ScriptedIngest
    private let current: IngestState

    init(inner: ScriptedIngest, state: IngestState) {
        self.inner = inner
        self.current = state
    }

    func latestSnapshot() async -> DeviceSnapshot? { await inner.latestSnapshot() }
    func state() -> IngestState { current }
    func updates() async -> AsyncStream<Void> { await inner.updates() }
    func scanNow() async -> UInt64? { await inner.scanNow() }
}

@Suite("ReaperIdleRun")
struct ReaperIdleRunTests {
    static let pk = DeletionScene.partkey
    static let other = "OTHERMIC"

    struct Fixture {
        let scene: DeletionScene
        let ingest: ScriptedIngest
        let runner: ScriptedProcessRunner
        let acting: ActingReaperRunner?
        let deps: DeletionDependencies
        let id: String
    }

    /// 要求を 1 件（DJIMIC3 宛て）書いた状態。act があれば `--home` の起動のときに行う（引数は舞台と要求の ID）
    static func fixture(
        exit: Int32 = 0, act: (@Sendable (DeletionScene, String) throws -> Void)? = nil
    ) async throws -> Fixture {
        let scene = try DeletionScene()
        let ingest = ScriptedIngest(snapshot: scene.snapshot())
        #expect(
            await DeletionRequester(deps: scene.deletionDependencies(ingest: ingest)).requestDeletions(
                sessionKey: DeletionScene.sessionKey) == 1)
        let id = try #require(try scene.store.recording(pk)?.deleteRequestID)
        let scripted = ScriptedProcessRunner(results: [
            ScriptedProcessRunner.version(), ScriptedProcessRunner.exited(exit),
        ])
        let acting = act.map { f in ActingReaperRunner(inner: scripted, act: { try f(scene, id) }) }
        let runner: any ProcessRunning = acting ?? scripted
        let locks = LockEvaluator(layout: scene.layout, verifier: scene.verifier, runner: runner, log: scene.log)
        return Fixture(
            scene: scene, ingest: ingest, runner: scripted, acting: acting,
            deps: scene.deletionDependencies(ingest: ingest, locks: locks), id: id)
    }

    static func run(_ f: Fixture, _ generation: UInt64 = 0) async -> UInt64 {
        await ResultCollector(deps: f.deps).runReaperIfNeeded(reaperScanGeneration: generation)
    }

    static func homeLaunches(_ runner: ScriptedProcessRunner) async -> Int {
        await runner.recorded.filter { $0.arguments.first == "--home" }.count
    }

    static func logged(_ scene: DeletionScene, _ body: String) -> Bool {
        scene.logLines.contains { $0.hasSuffix(" " + body) }
    }

    static func part(_ scene: DeletionScene) throws -> RecordingRow {
        try #require(try scene.store.recording(pk))
    }

    static func observation(_ scene: DeletionScene, deviceID: String, readOnly: Bool?) -> DeviceObservation {
        DeviceObservation(
            deviceID: deviceID,
            mountPath: scene.volumesRoot.appendingPathComponent(deviceID).path(percentEncoded: false),
            deviceNode: "/dev/disk8", readOnly: readOnly, freeBytes: 1_000_000_000, relpaths: [])
    }

    /// devices だけを差し替えた snapshot（generation 1・新鮮）
    static func snapshot(_ scene: DeletionScene, _ devices: [String: DeviceObservation]) -> DeviceSnapshot {
        DeviceSnapshot(
            generation: 1, completedAt: scene.clock.now(), connectEpoch: 1, devices: devices, unavailable: [:],
            notListableErrno: [:])
    }

    /// reaper が処理した姿: 要求を消し、その ID の DELETED の結果を書く
    static func consume(_ scene: DeletionScene, _ id: String) throws {
        for url in scene.requests() { try FileManager.default.removeItem(at: url) }
        try scene.writeResult(partkey: pk, requestID: id, status: .deleted, detail: DeletionScene.relpath)
    }

    static func request(deviceID: String, epoch: Int64) -> DeleteRequest {
        let partkey = deviceID + "/" + DeletionScene.relpath
        return DeleteRequest(
            requestID: RequestID.make(partkey: partkey, utcEpochSeconds: epoch, randomHex6: "abcdef"),
            createdAt: "2026-09-12T12:00:00+09:00", deviceID: deviceID, partkey: partkey,
            sessionKey: DeletionScene.sessionKey,
            target: DeleteTarget(relpath: DeletionScene.relpath, size: 4096, mtime: DeletionScene.sourceMtime))
    }

    // MARK: - (a) 起動の条件は要求の宛先のデバイス

    @Test(
        "F-79 要求の宛先が書き込み可能でなければ、別のデバイスが書き込み可能でも起動しない（パラメータ化: 宛先が無い・readOnly true・readOnly nil）",
        arguments: ["宛先が無い", "readOnly true", "readOnly nil"])
    func requestedDeviceMustBeWritable(_ kind: String) async throws {
        let f = try await Self.fixture()
        var devices = [Self.other: Self.observation(f.scene, deviceID: Self.other, readOnly: false)]
        switch kind {
        case "readOnly true":
            devices[DeletionScene.deviceID] = Self.observation(
                f.scene, deviceID: DeletionScene.deviceID, readOnly: true)
        case "readOnly nil":
            devices[DeletionScene.deviceID] = Self.observation(f.scene, deviceID: DeletionScene.deviceID, readOnly: nil)
        default:
            break
        }
        await f.ingest.setSnapshot(Self.snapshot(f.scene, devices))
        #expect(await Self.run(f, 3) == 3)
        // --version も起動しない（readiness より先に止まる）
        #expect(await f.runner.recorded == [])
        #expect(await f.ingest.scanNowCalls == 0)
        #expect(f.scene.requests().count == 1)
    }

    @Test("F-79 宛先のデバイスが書き込み可能なら起動する（ほかのデバイスが読み取り専用でも）")
    func requestedWritableDeviceLaunches() async throws {
        let f = try await Self.fixture()
        await f.ingest.setSnapshot(
            Self.snapshot(
                f.scene,
                [
                    DeletionScene.deviceID: Self.observation(
                        f.scene, deviceID: DeletionScene.deviceID, readOnly: false),
                    Self.other: Self.observation(f.scene, deviceID: Self.other, readOnly: true),
                ]))
        _ = await Self.run(f)
        #expect(await Self.homeLaunches(f.runner) == 1)
    }

    @Test("F-79 読める要求が 0 件（読めない要求だけ）なら起動しない")
    func onlyUnreadableRequestsNoLaunch() async throws {
        let f = try await Self.fixture()
        for url in f.scene.requests() { try FileManager.default.removeItem(at: url) }
        let junk = f.scene.layout.queueDelete.appendingPathComponent("20260912T030000Z-0000000000000000-abcdef.json")
        try Data("{".utf8).write(to: junk)
        #expect(await Self.run(f, 3) == 3)
        #expect(await f.runner.recorded == [])
        #expect(await f.ingest.scanNowCalls == 0)
    }

    @Test("F-79 要求が 0 件なら宛先のデバイスも 0 件")
    func emptyQueueHasNoRequestedDevices() throws {
        let tmp = try TempDirectory()
        let layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
        try layout.createDirectories()
        #expect(DeleteQueue.requestedDeviceIDs(layout: layout) == [])
        #expect(DeleteQueue.listing(layout: layout) == QueueListing(requests: [], results: []))
    }

    @Test("F-79 宛先のデバイスは読める要求の device_id を名前の順に（読めない要求は数えない）")
    func requestedDeviceIDsSkipUnreadable() throws {
        let tmp = try TempDirectory()
        let layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
        try layout.createDirectories()
        // 2026-09-12 03:00:00Z と 03:00:01Z。名前（= 時刻）の順は OTHERMIC → DJIMIC3
        try DeleteQueue.write(Self.request(deviceID: "DJIMIC3", epoch: 1_789_182_001), layout: layout)
        try DeleteQueue.write(Self.request(deviceID: Self.other, epoch: 1_789_182_000), layout: layout)
        try Data("{".utf8).write(to: layout.queueDelete.appendingPathComponent("20260912T030002Z-junk.json"))
        #expect(DeleteQueue.requestedDeviceIDs(layout: layout) == ["OTHERMIC", "DJIMIC3"])
    }

    @Test("F-79 宛先の device_id はスカラー単位で照合する（NFC と NFD は別のデバイス）")
    func deviceIDsAreComparedByScalars() throws {
        let scene = try DeletionScene()
        let nfd = "MIC\u{0065}\u{0301}"
        let snapshot = Self.snapshot(scene, [nfd: Self.observation(scene, deviceID: nfd, readOnly: false)])
        #expect(ResultCollector.anyWritable(["MIC\u{00E9}"], in: snapshot) == false)
        #expect(ResultCollector.anyWritable([nfd], in: snapshot) == true)
        #expect(ResultCollector.anyWritable([], in: snapshot) == false)
    }

    @Test(
        "F-79 走査中（reaper.lock を走査が持つ）は起動しない（パラメータ化: scanning・idle・disabled）",
        arguments: [IngestState.scanning, .idle, .disabled])
    func noLaunchWhileScanning(_ state: IngestState) async throws {
        let f = try await Self.fixture()
        let ingest = StatefulIngest(inner: f.ingest, state: state)
        let deps = f.scene.deletionDependencies(ingest: ingest, locks: f.deps.locks)
        let next = await ResultCollector(deps: deps).runReaperIfNeeded(reaperScanGeneration: 3)
        if state == .scanning {
            #expect(next == 3)
            // --version も起動しない（readiness より先に止まる）
            #expect(await f.runner.recorded == [])
            #expect(!Self.logged(f.scene, "reaper_failed reason=busy"))
        } else {
            #expect(await Self.homeLaunches(f.runner) == 1)
        }
        #expect(await f.ingest.scanNowCalls == 0)
        #expect(f.scene.requests().count == 1)
    }

    // MARK: - (b) 何も処理されなかった回は走査しない

    @Test("F-79 消費されない要求だけなら reaper の後に走査しない（パラメータ化: 終了コード 0・4 busy）", arguments: [Int32(0), 4])
    func unconsumedRequestDoesNotScan(_ code: Int32) async throws {
        let f = try await Self.fixture(exit: code)
        #expect(await Self.run(f) == 2)
        #expect(await Self.homeLaunches(f.runner) == 1)
        #expect(Self.logged(f.scene, "reaper_run exit=" + String(code)))
        #expect(await f.ingest.scanNowCalls == 0)
        #expect(f.scene.requests().count == 1)
        #expect(f.scene.results() == [])
    }

    @Test("F-79 何も処理されなかった回は DELETED を次に完了する走査まで残す（reaper の後の観測を待つ）")
    func unchangedRunWaitsForTheNextScan() async throws {
        let f = try await Self.fixture()
        // 前の回の DELETED（まだ回収されていない）。snapshot は generation 5 で、元ファイルがまだ一覧に在る
        await f.ingest.setSnapshot(f.scene.snapshot(generation: 5))
        try f.scene.writeResult(partkey: Self.pk, requestID: f.id, status: .deleted, detail: DeletionScene.relpath)
        #expect(await Self.run(f, 5) == 6)
        #expect(await f.ingest.scanNowCalls == 0)
        #expect(f.scene.results().count == 1)
        let part = try Self.part(f.scene)
        #expect(part.status == .sourceDeleting)
        #expect(part.deleteRequestID == f.id)
    }

    @Test(
        "F-79 処理されたら従来どおり走査して回収する（パラメータ化: 要求を消して結果を書いた・要求を消しただけ・結果を書いただけ）",
        arguments: ["消して書いた", "消しただけ", "書いただけ"])
    func processedRunScansAndCollects(_ kind: String) async throws {
        let f = try await Self.fixture(act: { scene, id in
            if kind != "書いただけ" {
                for url in scene.requests() { try FileManager.default.removeItem(at: url) }
            }
            if kind != "消しただけ" {
                try scene.writeResult(partkey: Self.pk, requestID: id, status: .deleted, detail: DeletionScene.relpath)
            }
        })
        await f.ingest.script([.publish(f.scene.snapshot(generation: 2, relpaths: []))])
        #expect(await Self.run(f) == 2)
        #expect(await f.acting?.actFailures == [])
        #expect(await f.ingest.scanNowCalls == 1)
        let part = try Self.part(f.scene)
        if kind == "消しただけ" {
            // 結果が無いので回収するものが無い（期限切れが決着させる）
            #expect(part.status == .sourceDeleting)
        } else {
            #expect(part.status == .completed)
            #expect(part.deleteRequestID == nil)
            #expect(f.scene.results() == [])
        }
    }

    @Test("F-79 処理された回の走査が見送られたら「今の generation + 1」を待つ")
    func processedRunWithSkippedScanWaits() async throws {
        let f = try await Self.fixture(act: { scene, id in try Self.consume(scene, id) })
        await f.ingest.setSnapshot(f.scene.snapshot(generation: 5, relpaths: []))
        await f.ingest.script([.skip])
        #expect(await Self.run(f) == 6)
        #expect(await f.ingest.scanNowCalls == 1)
        #expect(f.scene.results().count == 1)
        #expect(try Self.part(f.scene).status == .sourceDeleting)
    }
}
