// 「状態の詳細」（StatusReporter）の書式のテスト（T-32 §5.7）。DB が無ければ全 0。DB を作らない。
import Foundation
import GRDB
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice

@testable import VDPipeline
@testable import VDStore

@Suite("StatusReporter")
struct StatusReporterTests {
    static func build(
        _ w: DiagnosticsWorld, config: AppConfig? = DiagnosticsWorld.baseConfig(), snapshot: DeviceSnapshot? = nil
    )
        -> StatusReport
    {
        StatusReporter.build(
            layout: w.layout, config: config, snapshot: snapshot, now: w.clock.now(), zone: PipelineFixtures.zone)
    }

    /// 行を入れて、状態などを強制する（テストだけの近道。Tests/ は PT-05 の対象外）
    static func insert(
        _ store: Store, relpath: String, startedAt: String = "2026-08-29T07:12:04+09:00", duration: Double? = 1800,
        status: PartStatus, errorCode: String? = nil, retryCount: Int = 0, deleteRequestID: String? = nil
    ) throws {
        let row = try Builders.recording(relpath: relpath, startedAt: startedAt, durationSeconds: duration)
        try store.insertRecording(row)
        try store.pool.write { db in
            try db.execute(
                sql: "UPDATE recordings SET status = ?, error_code = ?, retry_count = ?, delete_request_id = ? "
                    + "WHERE partkey = ?",
                arguments: [status.rawValue, errorCode, retryCount, deleteRequestID, row.partkey])
        }
    }

    static func relpath(_ n: Int) -> String {
        let stamp = String(format: "%06d", 70_000 + n)
        return "TX_MIC001_20260829_" + stamp + "/TX01_MIC002_20260829_" + stamp + "_orig.wav"
    }

    @Test("DB が無ければ全 0")
    func allZeroWithoutDatabase() async throws {
        let w = try await DiagnosticsWorld.make()
        let r = Self.build(w)
        #expect(r.partCounts.count == 12)
        #expect(r.partCounts.allSatisfy { $0.1 == 0 })
        #expect(r.sessionCounts.count == 13)
        #expect(r.sessionCounts.allSatisfy { $0.1 == 0 })
        #expect(r.backlog == .empty)
        #expect(r.failedTotal == 0)
        #expect(!PipelineFixtures.exists(w.layout.database))
    }

    @Test("0 件の状態も出す")
    func everyStatusAppearsEvenAtZero() async throws {
        let w = try await DiagnosticsWorld.make()
        let store = try w.openStore()
        try Self.insert(store, relpath: Self.relpath(1), status: .discovered)
        let r = Self.build(w)
        #expect(r.partCounts.count == 12)
        #expect(r.partCounts.filter { $0.1 != 0 }.map(\.0) == [.discovered])
        #expect(r.partCounts.first { $0.0 == .discovered }?.1 == 1)
        #expect(r.lines.contains("  DISCOVERED: 1"))
        #expect(r.lines.contains("  NORMALIZING: 0"))
    }

    @Test("SKIPPED を FAILED の前に置く")
    func partOrderPutsSkippedBeforeFailed() {
        #expect(Array(StatusReporter.partOrder.suffix(2)) == [.skipped, .failed])
        #expect(
            Array(StatusReporter.partOrder.prefix(10)) == [
                .discovered, .normalizing, .normalized, .transcribing, .transcribed, .rawWriting, .rawSaved,
                .sourceDeleting, .sourceDeletePending, .completed,
            ])
        #expect(StatusReporter.partOrder.count == 12)
    }

    @Test("Session は宣言順")
    func sessionOrderIsDeclarationOrder() {
        #expect(StatusReporter.sessionOrder == SessionStatus.allCases)
        #expect(StatusReporter.sessionOrder.first == .open)
        #expect(StatusReporter.sessionOrder.last == .failed)
    }

    @Test("注記は Part の FAILED だけ")
    func onlyPartFailedHasANote() {
        #expect(StatusReporter.partNotes == [.failed: "次回接続時に再試行"])
        #expect(StatusReporter.sessionNotes.isEmpty)
    }

    @Test("Session の FAILED に注記を付けない")
    func sessionFailedHasNoNote() async throws {
        let w = try await DiagnosticsWorld.make()
        let store = try w.openStore()
        try store.insertSession(Builders.session())
        try await store.pool.write { db in
            try db.execute(sql: "UPDATE sessions SET status = ?", arguments: [SessionStatus.failed.rawValue])
        }
        let lines = Self.build(w).lines
        let start = try #require(lines.firstIndex(of: "Session"))
        let failedLine = try #require(lines[start...].first { $0.hasPrefix("  FAILED: ") })
        #expect(failedLine == "  FAILED: 1")
        #expect(!failedLine.contains("（"))
        #expect(lines.contains("  FAILED: 0（次回接続時に再試行）"))
    }

    @Test("（無音）を写さない")
    func skippedHasNoSilenceNote() async throws {
        let w = try await DiagnosticsWorld.make()
        let store = try w.openStore()
        for n in 1...3 { try Self.insert(store, relpath: Self.relpath(n), status: .skipped) }
        #expect(Self.build(w).lines.contains("  SKIPPED: 3"))
    }

    @Test("未処理の行は StatusTexts と同じ")
    func backlogLineIsShared() async throws {
        let w = try await DiagnosticsWorld.make()
        let store = try w.openStore()
        for n in 1...5 { try Self.insert(store, relpath: Self.relpath(n), duration: 2304, status: .discovered) }
        try Self.insert(store, relpath: Self.relpath(6), duration: nil, status: .discovered)
        let r = Self.build(w)
        #expect(r.backlog == BacklogCounts(count: 6, seconds: 11_520, unknownDuration: 1))
        #expect(r.lines.contains("未処理: 未処理 3.2 時間ぶん（6 件）、うち 1 件は長さ不明"))
    }

    @Test("started_at 昇順")
    func failedPartsAscendingByStartedAt() async throws {
        let w = try await DiagnosticsWorld.make()
        let store = try w.openStore()
        try Self.insert(store, relpath: Self.relpath(1), startedAt: "2026-08-29T09:00:00+09:00", status: .failed)
        try Self.insert(store, relpath: Self.relpath(2), startedAt: "2026-08-29T07:00:00+09:00", status: .failed)
        try Self.insert(store, relpath: Self.relpath(3), startedAt: "2026-08-29T08:00:00+09:00", status: .failed)
        let r = Self.build(w)
        #expect(
            r.failedParts.map(\.partkey) == [
                "DJIMIC3/" + Self.relpath(2), "DJIMIC3/" + Self.relpath(3), "DJIMIC3/" + Self.relpath(1),
            ])
    }

    @Test("1 行目が partkey、2 行目が詳細")
    func failedPartDetailFormat() async throws {
        let w = try await DiagnosticsWorld.make()
        let store = try w.openStore()
        try Self.insert(
            store, relpath: Self.relpath(1), startedAt: "2026-08-29T07:12:33+09:00", status: .failed,
            errorCode: "WHISPER_TIMEOUT", retryCount: 3)
        var c = DiagnosticsWorld.baseConfig()
        c.retry.maxAttempts = 3
        let lines = Self.build(w, config: c).lines
        let head = try #require(lines.firstIndex(of: "  DJIMIC3/" + Self.relpath(1)))
        #expect(lines[head + 1] == "    2026-08-29 07:12  WHISPER_TIMEOUT  retry 3/3")
        #expect(lines[head - 1] == "失敗した Part（1 件）")
    }

    @Test("error_code が無ければ unknown")
    func failedPartUnknownErrorCode() {
        let p = StatusReport.FailedPart(
            partkey: "DJIMIC3/a_orig.wav", startedAt: "2026-08-29T07:12:33+09:00", errorCode: nil, retryCount: 1)
        #expect(p.detail(maxAttempts: 3).contains("  unknown  "))
        #expect(p.detail(maxAttempts: 3) == "2026-08-29 07:12  unknown  retry 1/3")
    }

    @Test("ErrorCode に無いコードも生のまま出す（M-1）")
    func failedPartKeepsUnknownCodeString() async throws {
        let w = try await DiagnosticsWorld.make()
        let store = try w.openStore()
        try Self.insert(store, relpath: Self.relpath(1), status: .failed, errorCode: "FUTURE_CODE_X")
        let r = Self.build(w)
        #expect(r.failedParts.first?.errorCode == "FUTURE_CODE_X")
        #expect(r.lines.contains { $0.contains("  FUTURE_CODE_X  ") })
        #expect(!r.lines.contains { $0.contains("unknown") })
    }

    @Test("21 件目以降は『… ほか』")
    func failedPartsCapAt20() async throws {
        let w = try await DiagnosticsWorld.make()
        let store = try w.openStore()
        for n in 1...25 { try Self.insert(store, relpath: Self.relpath(n), status: .failed) }
        let r = Self.build(w)
        #expect(r.failedParts.count == 20)
        #expect(r.failedTotal == 25)
        #expect(r.lines.contains("  … ほか 5 件"))
        #expect(r.lines.contains("失敗した Part（25 件）"))
    }

    @Test("0 件なら見出しごと出さない")
    func noFailedSectionWhenZero() async throws {
        let w = try await DiagnosticsWorld.make()
        let store = try w.openStore()
        try Self.insert(store, relpath: Self.relpath(1), status: .completed)
        let lines = Self.build(w).lines
        #expect(!lines.contains { $0.hasPrefix("失敗した Part") })
        #expect(lines.last?.hasPrefix("デバイス: ") == true)
    }

    @Test("要求ファイルと結果待ち")
    func deleteQueueCounts() async throws {
        let w = try await DiagnosticsWorld.make()
        let store = try w.openStore()
        try Self.insert(store, relpath: Self.relpath(1), status: .sourceDeleting, deleteRequestID: "r1")
        try FileManager.default.createDirectory(at: w.layout.queueDelete, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: w.layout.queueDelete.appendingPathComponent("a.json"))
        try Data("{}".utf8).write(to: w.layout.queueDelete.appendingPathComponent("b.json"))
        #expect(Self.build(w).lines.contains("削除キュー: 要求 2 件、結果待ち 1 件"))
    }

    @Test("json でないファイルは数えない")
    func deleteQueueIgnoresNonJSON() async throws {
        let w = try await DiagnosticsWorld.make()
        try FileManager.default.createDirectory(at: w.layout.queueDelete, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: w.layout.queueDelete.appendingPathComponent("a.json"))
        try Data("x".utf8).write(to: w.layout.queueDelete.appendingPathComponent(".a.json.tmp"))
        try Data("x".utf8).write(to: w.layout.queueDelete.appendingPathComponent("note.txt"))
        let r = Self.build(w)
        #expect(r.deleteRequested == 1)
        #expect(r.lines.contains("削除キュー: 要求 1 件、結果待ち 0 件"))
    }

    @Test("staging の使用量と上限")
    func stagingUsage() async throws {
        let w = try await DiagnosticsWorld.make()
        let dir = w.layout.staging.appendingPathComponent("s1", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("a.wav")
        try Data().write(to: file)
        // 疎なファイル（1 GiB の論理サイズ。実際には書かない）
        let handle = try FileHandle(forUpdating: file)
        try handle.truncate(atOffset: 1_073_741_824)
        try handle.close()
        var c = DiagnosticsWorld.baseConfig()
        c.audio.stagingMaxBytes = 5 * 1_073_741_824
        #expect(Self.build(w, config: c).lines.contains("staging: 1.0 GiB / 5.0 GiB"))
    }

    @Test("#120 処理待ちと取り残しを分ける")
    func inboxSplitsPendingAndLeftover() async throws {
        let w = try await DiagnosticsWorld.make()
        let store = try w.openStore()
        try w.addInboxPart(store: store, relpath: Self.relpath(1), status: .rawSaved)
        try w.addInboxPart(store: store, relpath: Self.relpath(2), status: .discovered)
        try w.addInboxPart(store: store, relpath: Self.relpath(3), status: .transcribed)
        let r = Self.build(w)
        #expect(r.inbox == InboxCounts(pendingCount: 2, pendingBytes: 8, leftoverCount: 1, leftoverBytes: 4))
        #expect(r.lines.contains("inbox: 処理待ち 2 件 0.0 GiB、取り残し 1 件 0.0 GiB"))
    }

    @Test("まだ走査していなければ、そう出す")
    func deviceLineWhenNoSnapshot() async throws {
        let w = try await DiagnosticsWorld.make()
        #expect(Self.build(w, snapshot: nil).lines.contains("デバイス: まだ走査していません"))
    }

    @Test("#148 0 台は観測ではない")
    func deviceLineWhenZeroDevices() async throws {
        let w = try await DiagnosticsWorld.make()
        #expect(Self.build(w, snapshot: DiagnosticsWorld.snapshot()).lines.contains("デバイス: デバイス未接続"))
    }

    @Test("#107 nil を読み書き可能に丸めない")
    func deviceLineWordsFollowObservation() async throws {
        let w = try await DiagnosticsWorld.make()
        let s = DeviceSnapshot(
            generation: 1, completedAt: w.clock.now(), connectEpoch: 0,
            devices: [
                "DJIMIC3": DeviceObservation(
                    deviceID: "DJIMIC3", mountPath: "/tmp/vd-fake/DJIMIC3", deviceNode: nil, readOnly: nil,
                    freeBytes: 4_509_715_661, relpaths: [])
            ], unavailable: [:], notListableErrno: [:])
        #expect(Self.build(w, snapshot: s).lines.contains("デバイス: DJIMIC3 不明 空き 4.2 GiB"))
    }

    @Test("空きが分からなければ『空き 不明』")
    func deviceLineUnknownFreeSpace() async throws {
        let w = try await DiagnosticsWorld.make()
        let s = DiagnosticsWorld.snapshot(devices: ["DJIMIC3": false])
        #expect(Self.build(w, snapshot: s).lines.contains("デバイス: DJIMIC3 読み書き可能 空き 不明"))
    }

    @Test("同じ入力なら等しい")
    func reportIsEquatable() async throws {
        let w = try await DiagnosticsWorld.make()
        let store = try w.openStore()
        try w.addInboxPart(store: store, relpath: Self.relpath(1), status: .rawSaved)
        try Self.insert(store, relpath: Self.relpath(2), status: .failed, errorCode: "X")
        let s = DiagnosticsWorld.snapshot(devices: ["DJIMIC3": true])
        let a = Self.build(w, snapshot: s)
        let b = Self.build(w, snapshot: s)
        #expect(a == b)
        #expect(a != Self.build(w, snapshot: nil))
    }
}
