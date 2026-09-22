// StatusLine（パネル上端の 1 行・最終接続・空き容量・未処理）のテスト（T-30 §5.1）。
import Foundation
import Testing
import VDCore
import VDDevice
import VDPipeline

@testable import VoiceDockApp

@Suite("StatusLine")
struct StatusLineTests {
    static let now = Instant(epochMillis: 1_756_000_000_000)

    static func snapshot() -> AppSnapshot {
        var s = AppSnapshot(now: now)
        s.configPresent = true
        return s
    }

    static func observation(_ id: String, freeBytes: Int64?) -> DeviceObservation {
        DeviceObservation(
            deviceID: id, mountPath: "/tmp/" + id, deviceNode: nil, readOnly: nil, freeBytes: freeBytes, relpaths: [])
    }

    static func device(_ observations: [DeviceObservation]) -> DeviceSnapshot {
        var devices: [String: DeviceObservation] = [:]
        for o in observations { devices[o.deviceID] = o }
        return DeviceSnapshot(
            generation: 1, completedAt: now, connectEpoch: 1, devices: devices, unavailable: [:], notListableErrno: [:])
    }

    @Test("設定エラーは取り込み・処理より先")
    func configInvalidBeatsActivity() {
        var s = Self.snapshot()
        s.configPresent = false
        s.worker = WorkerStatus(
            activity: .transcribing(partkey: "k", startedAt: "2026-08-29T07:12:33+09:00"), paused: [])
        #expect(StatusLine.make(s) == "設定にエラーがあります")
    }

    @Test("取り込み中は件数と『抜いて大丈夫です』を出す")
    func ingestingShowsProgress() {
        var s = Self.snapshot()
        s.ingestActivity = IngestActivity(
            scanning: true, deviceID: "DJIMIC3", copied: 3, total: 12, lastActivityAt: Self.now)
        #expect(StatusLine.make(s) == "DJIMIC3 から取り込み中 3/12 — コピーが終われば抜いて大丈夫です")
    }

    @Test("候補 0 件の走査中は『調べています』")
    func scanningWithoutCandidates() {
        var s = Self.snapshot()
        s.ingestActivity = IngestActivity(scanning: true, deviceID: "DJIMIC3", copied: 0, total: 0, lastActivityAt: nil)
        #expect(StatusLine.make(s) == "デバイスを調べています")
    }

    @Test("文字起こし中は保存文字列の壁時計を出す")
    func transcribingShowsWallClock() {
        var s = Self.snapshot()
        s.worker = WorkerStatus(
            activity: .transcribing(partkey: "k", startedAt: "2026-08-29T07:12:33+09:00"), paused: [])
        #expect(StatusLine.make(s) == "文字起こし中 07:12 の録音")
    }

    @Test("変換中も同じ形")
    func normalizingShowsWallClock() {
        var s = Self.snapshot()
        s.worker = WorkerStatus(
            activity: .normalizing(partkey: "k", startedAt: "2026-08-29T07:12:33+09:00"), paused: [])
        #expect(StatusLine.make(s) == "変換中 07:12 の録音")
    }

    @Test("壊れた startedAt は『時刻不明』")
    func badStartedAtFallsBackToUnknown() {
        var s = Self.snapshot()
        s.worker = WorkerStatus(activity: .transcribing(partkey: "k", startedAt: "x"), paused: [])
        #expect(StatusLine.make(s) == "文字起こし中 時刻不明 の録音")
    }

    @Test("要約中は日付")
    func analyzingShowsDay() {
        var s = Self.snapshot()
        s.worker = WorkerStatus(activity: .analyzing(sessionKey: "s", dayDate: "2026-08-29"), paused: [])
        #expect(StatusLine.make(s) == "要約中 2026-08-29")
    }

    @Test("Daily の書き込み中")
    func writingDailyNoteShowsDay() {
        var s = Self.snapshot()
        s.worker = WorkerStatus(activity: .writingDailyNote(sessionKey: "s", dayDate: "2026-08-29"), paused: [])
        #expect(StatusLine.make(s) == "ノートを書いています 2026-08-29")
    }

    @Test("まとめ中・Raw の書き込み中")
    func mergingAndRawNote() {
        var s = Self.snapshot()
        s.worker = WorkerStatus(activity: .merging(sessionKey: "s"), paused: [])
        #expect(StatusLine.make(s) == "文字起こしをまとめています")
        s.worker = WorkerStatus(activity: .writingRawNote(sessionKey: "s"), paused: [])
        #expect(StatusLine.make(s) == "Raw ノートを書いています")
    }

    @Test("停止中の理由は PauseReason の宣言順")
    func pausedListsReasonsInDeclarationOrder() {
        var s = Self.snapshot()
        s.worker = WorkerStatus(activity: .idle, paused: [.llmNotSelected, .diskSpaceLow])
        #expect(StatusLine.make(s) == "停止中: 空き容量不足、LLM が未選択")
    }

    @Test("何もしていなければ待機中")
    func idleIsIdle() {
        #expect(StatusLine.make(Self.snapshot()) == "待機中")
    }

    @Test("接続中は名前を並べる")
    func lastConnectedShowsConnectedNames() {
        var s = Self.snapshot()
        s.device = Self.device([Self.observation("B", freeBytes: nil), Self.observation("A", freeBytes: nil)])
        let zone = ZonedTime(timeZone: TimeZone(identifier: "Asia/Tokyo") ?? .current)
        #expect(StatusLine.lastConnected(s, zone: zone) == "接続中（A、B）")
    }

    @Test("切れていれば最後に見た時刻")
    func lastConnectedShowsTimestamp() throws {
        var s = Self.snapshot()
        s.device = Self.device([])
        // 2026-08-28T22:12:33Z = 2026-08-29 07:12:33 +09:00
        s.lastConnectedAt = Instant(epochMillis: 1_787_955_153_000)
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(StatusLine.lastConnected(s, zone: ZonedTime(timeZone: tokyo)) == "2026-08-29 07:12")
    }

    @Test("一度も見ていなければ『まだありません』")
    func lastConnectedNever() {
        let zone = ZonedTime(fixedOffsetSeconds: 9 * 3600)
        #expect(StatusLine.lastConnected(Self.snapshot(), zone: zone) == "まだありません")
    }

    @Test("空き容量が観測できない台は出さない")
    func deviceFreeSkipsUnknown() {
        var s = Self.snapshot()
        s.device = Self.device([
            Self.observation("DJIMIC3", freeBytes: 4_509_715_660), Self.observation("DJIMIC3_2", freeBytes: nil),
        ])
        #expect(StatusLine.deviceFree(s) == "DJIMIC3 4.2 GiB")
    }

    @Test("1 台も観測が無ければ行を出さない")
    func deviceFreeNilWhenNoObservation() {
        var s = Self.snapshot()
        s.device = nil
        #expect(StatusLine.deviceFree(s) == nil)
    }

    @Test("TEST-28 何も無い観測")
    func emptySnapshotIsIdle() {
        let s = AppSnapshot(now: Self.now)
        var present = s
        present.configPresent = true
        let zone = ZonedTime(fixedOffsetSeconds: 0)
        // 既定の AppSnapshot は設定が読めていない側（configPresent = false。§4.7）。設定だけ読めている空の観測は待機中
        #expect(StatusLine.make(s) == "設定にエラーがあります")
        #expect(StatusLine.make(present) == "待機中")
        #expect(StatusLine.backlog(s) == "未処理なし")
        #expect(StatusLine.lastConnected(s, zone: zone) == "まだありません")
        #expect(StatusLine.deviceFree(s) == nil)
    }
}
