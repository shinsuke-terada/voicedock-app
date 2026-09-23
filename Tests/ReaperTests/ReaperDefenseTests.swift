// voicedock-reaper の防御の追加（PLAN F-73・issue #113）。走行中の無効化・取り下げと重なった要求・replayed の書き込みの失敗・
// FIFO で止まらない・symlink を辿って書かない。unlink（RV-13）まで進む経路は普通のディレクトリでは RV-06 で弾かれるので、
// その段だけは @testable import で FakeVolume の上の検証済みの対象に直接当てる（PLAN §10.5 の層 R2 と同じ作り）。
// ボリュームは一時ディレクトリ（/Volumes には触れない）。
import Darwin
import Foundation
import Synchronization
import TestSupport
import Testing
import VDContract

@testable import voicedock_reaper

@Suite("voicedock-reaper の防御（F-73）")
struct ReaperDefenseTests {
    static let id = ReaperBench.requestID
    static let deviceID = "VDT0073"
    static let folder = "TX_MIC001_20260912_090000"
    static let file = "TX00_MIC001_20260912_090000_orig.wav"
    static let rel = folder + "/" + file
    static let mtime = 1_787_000_000.0

    /// プロセス内で RequestProcessor を組む舞台（reaper の実行ファイルは起動しない）
    struct Stage {
        let tmp: TempDirectory
        let layout: HomeLayout
        let log: ReaperLog
        let queue: QueueFiles

        init() throws {
            tmp = try TempDirectory()
            layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
            try layout.createDirectories()
            try FileManager.default.createDirectory(at: layout.binDirectory, withIntermediateDirectories: true)
            log = ReaperLog(url: layout.reaperLog)
            guard let queue = QueueFiles.make(layout: layout) else {
                throw BenchError(description: "queue/delete を開けない")
            }
            self.queue = queue
        }

        /// 起動時に読んだ conf は true（ロック 1 が開いた状態で走査に入った）
        func processor() -> RequestProcessor {
            RequestProcessor(
                layout: layout,
                conf: ReaperConf(
                    deleteSourceAudio: true,
                    volumesRoot: tmp.url.appendingPathComponent("Volumes").path(percentEncoded: false)),
                queue: queue, log: log, clock: ReaperClock(), processed: ProcessedLog(url: layout.processedLog))
        }

        func writeConf(_ text: String) throws {
            try Data(text.utf8).write(to: layout.reaperConf)
        }

        func names(in directory: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? [])
                .sorted()
        }

        /// 「何も書かない」: 結果・退避・processed.log・reaper.log のどれも無い
        func expectNothingWritten() {
            #expect(names(in: layout.queueResult) == [])
            #expect(names(in: layout.queueRejected) == [])
            #expect(!FileManager.default.fileExists(atPath: layout.processedLog.path(percentEncoded: false)))
            #expect(!FileManager.default.fileExists(atPath: layout.reaperLog.path(percentEncoded: false)))
        }
    }

    /// FakeVolume の上の原本 1 つと、それを開いたボリューム
    struct Volume {
        let fake: FakeVolume
        let handle: VolumeHandle

        init(in tmp: TempDirectory) throws {
            fake = try FakeVolume(in: tmp, deviceID: ReaperDefenseTests.deviceID)
            try fake.addFile(ReaperDefenseTests.rel, mtime: ReaperDefenseTests.mtime)
            let opened = FakeVolumeOpener().open(
                volumesRoot: fake.volumesRoot.path(percentEncoded: false), deviceID: ReaperDefenseTests.deviceID)
            guard case .opened(let handle) = opened else {
                throw BenchError(description: "FakeVolumeOpener がボリュームを開けなかった")
            }
            self.handle = handle
        }

        /// 検証（RV-08〜RV-12）を通った対象に、本番と同じ body（unlink の直前の読み直し → unlink）を当てる
        func verifyAndUnlink(confURL: URL) -> Result<RequestProcessor.UnlinkStep, IdentityMismatch> {
            TargetIdentity.withVerifiedTarget(
                volume: handle, relpath: ReaperDefenseTests.rel, expectedSize: 4096,
                expectedMtime: ReaperDefenseTests.mtime
            ) { target in
                RequestProcessor.unlinkIfLock1Open(target, confURL: confURL)
            }
        }

        var sourceExists: Bool { fake.fileStat(ReaperDefenseTests.rel) != nil }
    }

    // MARK: - A3 走行中の無効化（unlink の直前に reaper.conf を読み直す）

    @Test(
        "RV-01 ロック 1 の判定: true は開き、false は lock1、無い・空・不正は conf_invalid",
        arguments: [
            ("SCHEMA=1\nDELETE_SOURCE_AUDIO=true\nVOLUMES_ROOT=/x\n", "open"),
            ("SCHEMA=1\nDELETE_SOURCE_AUDIO=false\nVOLUMES_ROOT=/x\n", "lock1"),
            ("<none>", "conf_invalid"),
            ("", "conf_invalid"),
            ("SCHEMA=1\nDELETE_SOURCE_AUDIO=yes\n", "conf_invalid"),
        ])
    func rv01Lock1ClosedReasonTable(_ text: String, _ expected: String) throws {
        let stage = try Stage()
        if text != "<none>" { try stage.writeConf(text) }
        let reason = RequestProcessor.lock1ClosedReason(ReaperConf.observe(at: stage.layout.reaperConf))
        #expect((reason ?? "open") == expected)
    }

    @Test(
        "RV-01 unlink の直前に読み直した reaper.conf でロック 1 が閉じていれば消さない（走行中の無効化）",
        arguments: [
            ("SCHEMA=1\nDELETE_SOURCE_AUDIO=false\nVOLUMES_ROOT=/x\n", "lock1"),
            ("<none>", "conf_invalid"),
            ("SCHEMA=1\nDELETE_SOURCE_AUDIO=true\nEXTRA=1\n", "conf_invalid"),
        ])
    func rv01Lock1ClosedJustBeforeUnlinkKeepsTheSource(_ text: String, _ expected: String) throws {
        let stage = try Stage()
        let volume = try Volume(in: stage.tmp)
        if text != "<none>" { try stage.writeConf(text) }
        let outcome = volume.verifyAndUnlink(confURL: stage.layout.reaperConf)
        #expect(outcome == .success(.lock1Closed(expected)))
        #expect(volume.sourceExists)
    }

    @Test("RV-13 対照: unlink の直前の読み直しでロック 1 が開いていれば本当に消える")
    func rv13Lock1OpenJustBeforeUnlinkDeletes() throws {
        let stage = try Stage()
        let volume = try Volume(in: stage.tmp)
        try stage.writeConf("SCHEMA=1\nDELETE_SOURCE_AUDIO=true\nVOLUMES_ROOT=/x\n")
        let outcome = volume.verifyAndUnlink(confURL: stage.layout.reaperConf)
        #expect(outcome == .success(.unlinked(.ok)))
        #expect(!volume.sourceExists)
    }

    @Test("RV-01 reaper.conf が FIFO なら開くところで止まらずに conf_invalid（消さない）")
    func rv01FIFOConfIsConfInvalidWithoutBlocking() throws {
        let stage = try Stage()
        let volume = try Volume(in: stage.tmp)
        let path = stage.layout.reaperConf.path(percentEncoded: false)
        #expect(mkfifo(path, 0o644) == 0)
        let watchdog = FIFOWatchdog(path: path)
        let outcome = volume.verifyAndUnlink(confURL: stage.layout.reaperConf)
        #expect(!watchdog.finish(), "reaper.conf の FIFO を開くところで止まった")
        #expect(outcome == .success(.lock1Closed("conf_invalid")))
        #expect(volume.sourceExists)
    }

    // MARK: - 走査の本体（ReaperMain.scan）

    @Test("RV-01 走査は unlink の直前でロック 1 が閉じたら残りの要求に進まずに終える（lock1 は 0、それ以外は 2）")
    func rv01ScanStopsAtAClosedLock() {
        // 知らない理由語は 2（0 にするのは lock1 のときだけ。fail-closed）
        for (reason, code) in [("lock1", Int32(0)), ("conf_invalid", Int32(2)), ("unknown", Int32(2))] {
            var seen: [String] = []
            let outcomes: [String: RequestOutcome] = [
                "a": .refused("not_a_mount_point"), "b": .stopped(reason), "c": .refused("not_a_mount_point"),
            ]
            let scanned = ReaperMain.scan(
                ["a", "b", "c"], stopRequested: { false },
                process: { name in
                    seen.append(name)
                    return outcomes[name] ?? .left("device_absent")
                })
            #expect(seen == ["a", "b"])
            #expect(scanned.requests == 1)
            #expect(scanned.code == code)
        }
    }

    @Test("F-73 走査は列挙の後に消えていた要求を数えずに次へ進む")
    func f73ScanSkipsVanishedRequestsWithoutCounting() {
        var seen: [String] = []
        let outcomes: [String: RequestOutcome] = [
            "a": .gone, "b": .refused("not_a_mount_point"), "c": .gone, "d": .left("device_absent"),
        ]
        let scanned = ReaperMain.scan(
            ["a", "b", "c", "d"], stopRequested: { false },
            process: { name in
                seen.append(name)
                return outcomes[name] ?? .left("device_absent")
            })
        #expect(seen == ["a", "b", "c", "d"])
        #expect(scanned.requests == 2)
        #expect(scanned.code == 0)
    }

    @Test("F-73 要求が 0 件の走査は 0 件で終了コード 0（TEST-28）")
    func f73ScanOfNoRequests() {
        var calls = 0
        let scanned = ReaperMain.scan(
            [], stopRequested: { false },
            process: { _ in
                calls += 1
                return .gone
            })
        #expect(calls == 0)
        #expect(scanned.requests == 0)
        #expect(scanned.code == 0)
    }

    // MARK: - A2 取り下げと重なった要求（ENOENT）

    @Test("F-73 列挙の後に消えた要求（ENOENT）は何も書かずに飛ばす（partkey の無い結果を書かない）")
    func f73VanishedRequestWritesNothing() throws {
        let stage = try Stage()
        var proc = stage.processor()
        let outcome = proc.process(name: Self.id + ".json")
        #expect(outcome == .gone)
        stage.expectNothingWritten()
    }

    @Test("F-73 対照: 在るのに読めない要求（ディレクトリ）はこれまでどおり malformed_request")
    func f73UnreadableRequestIsStillMalformed() throws {
        let stage = try Stage()
        try FileManager.default.createDirectory(
            at: stage.layout.queueDelete.appendingPathComponent(Self.id + ".json"), withIntermediateDirectories: false)
        var proc = stage.processor()
        let outcome = proc.process(name: Self.id + ".json")
        #expect(outcome == .refused("malformed_request"))
        let data = try Data(contentsOf: stage.layout.queueResult.appendingPathComponent(Self.id + ".json"))
        guard case .success(let result) = ContractJSON.decodeResult(data) else {
            Issue.record("結果を読めない")
            return
        }
        #expect(result.status == .sourceIdentityMismatch)
        #expect(result.detail == "malformed_request")
        #expect(result.partkey == "")
    }

    @Test("F-73 要求が FIFO なら開くところで止まらずに malformed_request")
    func f73FIFORequestIsMalformedWithoutBlocking() throws {
        let stage = try Stage()
        let path = stage.layout.queueDelete.appendingPathComponent(Self.id + ".json").path(percentEncoded: false)
        #expect(mkfifo(path, 0o644) == 0)
        let watchdog = FIFOWatchdog(path: path)
        var proc = stage.processor()
        let outcome = proc.process(name: Self.id + ".json")
        #expect(!watchdog.finish(), "要求の FIFO を開くところで止まった")
        #expect(outcome == .refused("malformed_request"))
    }

    // MARK: - A4 replayed の結果を書けなければ要求を残す（層 R1。実行ファイルを起動する）

    @Test("RV-04 replayed の結果を書けなければ要求を残し、拒否のログも出さない")
    func rv04ReplayedKeepsTheRequestWhenTheResultCannotBeWritten() throws {
        let bench = try ReaperBench()
        try Data((Self.id + "\n").utf8).write(to: bench.layout.processedLog)
        let name = try bench.writeRequest()
        let resultDir = bench.layout.queueResult.path(percentEncoded: false)
        #expect(chmod(resultDir, 0o555) == 0)
        defer { _ = chmod(resultDir, 0o755) }
        let run = try bench.run()
        #expect(run.exitCode == 0)
        #expect(bench.requests() == [name])
        #expect(bench.results() == [])
        #expect(bench.processedLines() == [Self.id])
        #expect(bench.logLines().allSatisfy { !$0.contains(" source_delete_rejected ") }, "\(bench.logLines())")
        #expect(bench.logLines().last?.hasSuffix(" INFO  reaper_completed requests=1") == true)
        #expect(bench.sourceExists())
    }

    // MARK: - A6 processed.log の FIFO / A7 symlink を辿って書かない

    @Test("F-73 processed.log が FIFO なら開くところで止まらずに読めない扱い（どの ID もリプレイ）")
    func f73FIFOProcessedLogIsFailClosedWithoutBlocking() throws {
        let stage = try Stage()
        let path = stage.layout.processedLog.path(percentEncoded: false)
        #expect(mkfifo(path, 0o644) == 0)
        let watchdog = FIFOWatchdog(path: path)
        let processed = ProcessedLog(url: stage.layout.processedLog)
        #expect(!watchdog.finish(), "processed.log の FIFO を開くところで止まった")
        #expect(processed.contains(Self.id))
    }

    @Test("F-73 processed.log が FIFO でも追記は開くところで止まらずに失敗する")
    func f73FIFOProcessedLogAppendFailsWithoutBlocking() throws {
        let stage = try Stage()
        let path = stage.layout.processedLog.path(percentEncoded: false)
        #expect(mkfifo(path, 0o644) == 0)
        let watchdog = FIFOWatchdog(path: path)
        var processed = ProcessedLog(url: stage.layout.processedLog)
        let appended = processed.append(Self.id)
        #expect(!watchdog.finish(), "processed.log の FIFO を開くところで止まった")
        #expect(!appended)
    }

    @Test("F-73 processed.log が symlink なら辿った先に追記しない（無い先を作らない）", arguments: [true, false])
    func f73SymlinkedProcessedLogIsNotFollowed(_ targetExists: Bool) throws {
        let stage = try Stage()
        let outside = stage.tmp.url.appendingPathComponent("outside.log")
        if targetExists { try Data("keep\n".utf8).write(to: outside) }
        try FileManager.default.createSymbolicLink(
            atPath: stage.layout.processedLog.path(percentEncoded: false),
            withDestinationPath: outside.path(percentEncoded: false))
        var processed = ProcessedLog(url: stage.layout.processedLog)
        let appended = processed.append(Self.id)
        #expect(!appended)
        if targetExists {
            #expect(try Data(contentsOf: outside) == Data("keep\n".utf8))
        } else {
            #expect(!FileManager.default.fileExists(atPath: outside.path(percentEncoded: false)))
        }
    }

    @Test("F-73 reaper.log が symlink なら辿った先に書かない（無い先を作らない）", arguments: [true, false])
    func f73SymlinkedReaperLogIsNotFollowed(_ targetExists: Bool) throws {
        let stage = try Stage()
        let outside = stage.tmp.url.appendingPathComponent("outside.log")
        if targetExists { try Data("keep\n".utf8).write(to: outside) }
        try FileManager.default.createSymbolicLink(
            atPath: stage.layout.reaperLog.path(percentEncoded: false),
            withDestinationPath: outside.path(percentEncoded: false))
        stage.log.info(ReaperLog.Event.started)
        stage.log.close()
        if targetExists {
            #expect(try Data(contentsOf: outside) == Data("keep\n".utf8))
        } else {
            #expect(!FileManager.default.fileExists(atPath: outside.path(percentEncoded: false)))
        }
    }

    @Test("F-73 reaper.log が FIFO でも開くところで止まらない")
    func f73FIFOReaperLogDoesNotBlock() throws {
        let stage = try Stage()
        let path = stage.layout.reaperLog.path(percentEncoded: false)
        #expect(mkfifo(path, 0o644) == 0)
        let watchdog = FIFOWatchdog(path: path)
        stage.log.info(ReaperLog.Event.started)
        stage.log.close()
        #expect(!watchdog.finish(), "reaper.log の FIFO を開くところで止まった")
    }
}

/// FIFO の見張り。猶予（3 秒）を過ぎても finish() が呼ばれなければ、テストしている呼び出しが FIFO を開くところで止まったと
/// みなして反対側を開いて解き、finish() が真を返す（テストはそれで落ちる）。直した実装は止まらないので猶予に届かない。
/// 壊した実装が止まったまま終わらないテストにしないための仕掛け。止まった読み手には書き手を開いて少し後に閉じる
/// （読み手は EOF を見る）。止まった書き手には読み手を開いて finish() まで持つ（先に閉じると書き手が SIGPIPE を受けるため）
final class FIFOWatchdog: Sendable {
    static let graceMicros: UInt32 = 3_000_000
    static let tickMicros: UInt32 = 20_000

    private let stopped = Atomic<Bool>(false)
    private let unblocked = Atomic<Bool>(false)
    private let readerFD = Atomic<Int32>(-1)
    private let done = DispatchSemaphore(value: 0)

    init(path: String) {
        Thread.detachNewThread { [self] in
            var waited: UInt32 = 0
            while !stopped.load(ordering: .relaxed) {
                if waited >= Self.graceMicros {
                    // 猶予を過ぎてもまだ終わっていない = 止まった
                    unblocked.store(true, ordering: .relaxed)
                    // 止まった読み手を解く（読み手が居なければ ENXIO で何もしない）
                    let writer = open(path, O_WRONLY | O_NONBLOCK)
                    if writer >= 0 {
                        usleep(200_000)
                        close(writer)
                    }
                    // 止まった書き手を解く（O_NONBLOCK の読み手はすぐ開ける）
                    if readerFD.load(ordering: .relaxed) < 0 {
                        let reader = open(path, O_RDONLY | O_NONBLOCK)
                        if reader >= 0 { readerFD.store(reader, ordering: .relaxed) }
                    }
                }
                usleep(Self.tickMicros)
                waited += Self.tickMicros
            }
            let reader = readerFD.load(ordering: .relaxed)
            if reader >= 0 { close(reader) }
            done.signal()
        }
    }

    /// 見張りを止め（見張りのスレッドが終わるまで待つ）、解いたかどうかを返す
    func finish() -> Bool {
        stopped.store(true, ordering: .relaxed)
        done.wait()
        return unblocked.load(ordering: .relaxed)
    }
}
