// 再コピー（needs_recopy の Part を取り直したとき）で長さを測り直す（PLAN §8.1・§8.3・F-81・issue #119）。
// 取り込みの舞台は IngestCopyTests と同じ（FakeVolume の一時ディレクトリ。デバイスの原本は読むだけ）。
import Foundation
import SQLite3
import TestSupport
import Testing
import VDContract
import VDCore
import VDStore

@testable import VDDevice

@Suite("再コピーの長さの測り直し（F-81）", .serialized)
struct IngestRecopyDurationTests {
    static let pk120950 = IngestCopyTests.pk120950
    static let pk163444 = IngestCopyTests.pk163444
    static let sessionKey = "DJIMIC3:20260912"
    /// 1.5 秒の BWF（DefaultDeviceTree.bytes120950）のファイル名の時刻と、その 1.5 秒後（秒未満切り捨て）
    static let started120950 = "2026-09-12T12:09:50+09:00"
    static let ended120950 = "2026-09-12T12:09:51+09:00"

    /// 最初のコピーの後に、登録のときヘッダが短かった（0.5 秒と測った）状態を作り、needs_recopy を立てる
    static func registerShortAndMarkRecopy(_ h: IngestCopyTests.Harness) throws {
        try h.store.updateRecording(
            Self.pk120950, [.durationSeconds(0.5), .endedAt(Self.started120950), .needsRecopy(true)])
    }

    /// Session を作り、pk120950 をそこに入れて集計を数える
    static func putIntoSession(_ h: IngestCopyTests.Harness) throws {
        try h.store.insertSession(NewSession(sessionKey: Self.sessionKey, dayDate: "2026-09-12", deviceID: "DJIMIC3"))
        try h.store.updateRecording(Self.pk120950, [.sessionKey(Self.sessionKey)])
        try h.store.refreshSessionAggregates(Self.sessionKey)
    }

    @Test("F-81 最初のコピーは従来どおり（ended_at はファイル名の時刻 + 測った長さ）")
    func firstCopyIsUnchanged() async throws {
        let h = try IngestCopyTests.Harness()
        try DefaultDeviceTree.populate(h.fake)
        _ = await h.run()
        let a = try #require(try h.store.recording(Self.pk120950))
        #expect(a.startedAt == Self.started120950)
        #expect(a.durationSeconds == 1.5)
        #expect(a.endedAt == Self.ended120950)
        let b = try #require(try h.store.recording(Self.pk163444))
        #expect(b.startedAt == "2026-09-12T16:34:44+09:00")
        #expect(b.durationSeconds == 2.0)
        #expect(b.endedAt == "2026-09-12T16:34:46+09:00")
    }

    @Test("F-81 再コピーで duration_seconds と ended_at を取り直したファイルの長さに書き直す（原本は読むだけ）")
    func recopyRemeasuresDuration() async throws {
        let h = try IngestCopyTests.Harness()
        try DefaultDeviceTree.populate(h.fake)
        _ = await h.run()
        try Self.registerShortAndMarkRecopy(h)
        let second = await h.run()
        #expect(second.copied == 1)
        let row = try #require(try h.store.recording(Self.pk120950))
        #expect(row.startedAt == Self.started120950)
        #expect(row.durationSeconds == 1.5)
        #expect(row.endedAt == Self.ended120950)
        #expect(row.needsRecopy == false)
        #expect(row.sessionKey == nil)
        #expect(row.status == .discovered)
        // デバイスの原本は書き換えない
        #expect(try Data(contentsOf: h.fake.url(DefaultDeviceTree.orig120950)) == DefaultDeviceTree.bytes120950())
        #expect(h.fake.fileStat(DefaultDeviceTree.orig120950)?.mtime == FakeVolume.oldMtime)
    }

    @Test("F-81 再コピーで長さが変われば、属する Session の recorded_seconds と ended_at も数え直す")
    func recopyRecountsSessionAggregates() async throws {
        let h = try IngestCopyTests.Harness()
        try DefaultDeviceTree.populate(h.fake)
        _ = await h.run()
        try Self.putIntoSession(h)
        try Self.registerShortAndMarkRecopy(h)
        try h.store.refreshSessionAggregates(Self.sessionKey)
        // 準備の確かめ: Session は短い長さで数えてある
        let stale = try #require(try h.store.session(Self.sessionKey))
        try #require(stale.recordedSeconds == 0.5)
        try #require(stale.endedAt == Self.started120950)
        _ = await h.run()
        let session = try #require(try h.store.session(Self.sessionKey))
        #expect(session.recordedSeconds == 1.5)
        #expect(session.startedAt == Self.started120950)
        #expect(session.endedAt == Self.ended120950)
        #expect(session.partCount == 1)
    }

    @Test("F-81 再コピーで長さを測れなければ（AudioProbe が nil）、登録済みの duration_seconds と ended_at を残す")
    func unmeasurableRecopyKeepsDuration() async throws {
        let h = try IngestCopyTests.Harness()
        try DefaultDeviceTree.populate(h.fake)
        _ = await h.run()
        try h.store.updateRecording(Self.pk120950, [.needsRecopy(true)])
        // 取り直す原本を音声として読めない中身にする（一時ディレクトリの FakeVolume の上だけ）
        try h.fake.addFile(DefaultDeviceTree.orig120950, data: Data("not a wav".utf8), mtime: FakeVolume.oldMtime)
        let second = await h.run()
        #expect(second.copied == 1)
        let row = try #require(try h.store.recording(Self.pk120950))
        #expect(row.durationSeconds == 1.5)
        #expect(row.endedAt == Self.ended120950)
        #expect(row.sourceSize == 9)
        #expect(row.needsRecopy == false)
    }

    @Test("F-81 登録のとき長さが NULL（測れなかった）なら、再コピーで測れた長さで埋める（TEST-28）")
    func recopyFillsNullDuration() async throws {
        let h = try IngestCopyTests.Harness()
        try h.fake.addFile(DefaultDeviceTree.orig120950, data: Data("not a wav".utf8), mtime: FakeVolume.oldMtime)
        _ = await h.run()
        let first = try #require(try h.store.recording(Self.pk120950))
        try #require(first.durationSeconds == nil)
        try #require(first.endedAt == nil)
        try h.store.updateRecording(Self.pk120950, [.needsRecopy(true)])
        try h.fake.addFile(
            DefaultDeviceTree.orig120950, data: try DefaultDeviceTree.bytes120950(), mtime: FakeVolume.oldMtime)
        _ = await h.run()
        let row = try #require(try h.store.recording(Self.pk120950))
        #expect(row.durationSeconds == 1.5)
        #expect(row.endedAt == Self.ended120950)
    }

    @Test("F-81 再コピーの ended_at は登録済みの started_at の瞬間とオフセットで書く（タイムゾーンを変えた後でも開始の 1.5 秒後）")
    func recopyEndedAtCountsFromStoredStart() async throws {
        let h = try IngestCopyTests.Harness()
        try DefaultDeviceTree.populate(h.fake)
        _ = await h.run()
        try Self.registerShortAndMarkRecopy(h)
        // 設定のタイムゾーンを UTC に変えた後の取り込み（同じ HOME・DB・デバイス）。RK-32
        let clock = FixedClock(epochMillis: 1_790_000_000_000)
        let utc = ZonedTime(fixedOffsetSeconds: 0)
        let config = h.config
        let service = IngestService(
            deps: IngestDependencies(
                layout: h.layout, configProvider: { config }, store: h.store, inspector: FakeMountInspector(),
                remounter: FakeRemounter(outcomes: [.alreadyReadOnly]), mountEvents: FakeMountEventSource(),
                reader: DeviceReader(), clock: clock, sleeper: RecordingSleeper(), zone: utc,
                log: AppLog(sink: CapturingLogSink(), level: .debug, unsafeContent: false, zone: utc, clock: clock),
                volumesRoot: h.fake.volumesRoot.path(percentEncoded: false)))
        _ = await service.ingestDevice(deviceID: "DJIMIC3", mountPath: h.mountPath, config: config)
        let row = try #require(try h.store.recording(Self.pk120950))
        #expect(row.startedAt == Self.started120950)
        #expect(row.durationSeconds == 1.5)
        // 2026-09-12T12:09:50+09:00 の 1.5 秒後を started_at と同じ +09:00 で（voicedock の started_at + timedelta と同じ）。
        // 設定のタイムゾーン（UTC）で書くと 03:09:51+00:00、ファイル名の時刻を UTC とみなすと 12:09:51+00:00（開始の 9 時間後）になる
        #expect(row.endedAt == "2026-09-12T12:09:51+09:00")
    }

    @Test("F-81 再コピーで測った長さが登録と同じなら、Session の集計を書き直さない")
    func sameDurationDoesNotTouchSession() async throws {
        let h = try IngestCopyTests.Harness()
        try DefaultDeviceTree.populate(h.fake)
        _ = await h.run()
        try Self.putIntoSession(h)
        // 目印: 数え直されれば 1.5 に戻る
        try h.store.updateSession(Self.sessionKey, [.recordedSeconds(99)])
        try h.store.updateRecording(Self.pk120950, [.needsRecopy(true)])
        let second = await h.run()
        #expect(second.copied == 1)
        #expect(try h.store.session(Self.sessionKey)?.recordedSeconds == 99)
        let row = try #require(try h.store.recording(Self.pk120950))
        #expect(row.durationSeconds == 1.5)
        #expect(row.endedAt == Self.ended120950)
    }

    struct SetupError: Error {
        let message: String
    }

    /// DB の sessions の更新だけを失敗させる（Session の集計の書き込みの失敗を作る。一時ディレクトリの DB だけ）
    static func failSessionUpdates(_ h: IngestCopyTests.Harness) throws {
        var db: OpaquePointer?
        guard sqlite3_open(h.layout.database.path(percentEncoded: false), &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw SetupError(message: "DB を開けない")
        }
        defer { sqlite3_close(db) }
        let sql =
            "CREATE TRIGGER f81_fail_session_update BEFORE UPDATE ON sessions "
            + "BEGIN SELECT RAISE(ABORT, 'f81'); END"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SetupError(message: "trigger を作れない") }
    }

    @Test("F-81 Session の集計を数え直せなくても取り込みの失敗にせず、行は新しい長さで、DB の例外を config_warning rule=store で残す")
    func sessionAggregateFailureIsNotCopyFailure() async throws {
        let h = try IngestCopyTests.Harness()
        try DefaultDeviceTree.populate(h.fake)
        _ = await h.run()
        try Self.putIntoSession(h)
        try Self.registerShortAndMarkRecopy(h)
        try h.store.refreshSessionAggregates(Self.sessionKey)
        try Self.failSessionUpdates(h)
        let second = await h.run()
        #expect(second.copied == 1)
        let row = try #require(try h.store.recording(Self.pk120950))
        #expect(row.durationSeconds == 1.5)
        #expect(row.endedAt == Self.ended120950)
        #expect(row.needsRecopy == false)
        // 集計は古いまま（次に同じ Session へ Part が分組されるときに数え直される）
        #expect(try h.store.session(Self.sessionKey)?.recordedSeconds == 0.5)
        #expect(h.lines(containing: " copy_failed ").isEmpty)
        #expect(h.sink.lines.contains { $0.hasSuffix("WARNING config_warning rule=store message=DatabaseError") })
        #expect(
            h.sink.lines.contains {
                $0.hasSuffix("INFO  copy_completed recording_key=\(Self.pk120950) bytes=248776 recopy=true")
            })
    }

    @Test("F-81 ISO のオフセットを秒で読む（±HH:MM・±HH:MM:SS。形が違えば nil）")
    func isoOffsetSecondsReadsFixedForms() {
        #expect(IngestService.isoOffsetSeconds("2026-09-12T12:09:50+09:00") == 32_400)
        #expect(IngestService.isoOffsetSeconds("2026-09-12T12:09:50-05:30") == -19_800)
        #expect(IngestService.isoOffsetSeconds("2026-09-12T12:09:50+00:00") == 0)
        #expect(IngestService.isoOffsetSeconds("2026-09-12T12:09:50+05:30:15") == 19_815)
        #expect(IngestService.isoOffsetSeconds("2026-09-12T12:09:50Z") == nil)
        #expect(IngestService.isoOffsetSeconds("2026-09-12T12:09:50+0a:00") == nil)
    }

    @Test("F-81 ISO のオフセットは空文字なら nil（TEST-28）")
    func isoOffsetSecondsOfEmptyIsNil() {
        #expect(IngestService.isoOffsetSeconds("") == nil)
    }
}
