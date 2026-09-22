// AppModel の最終接続の永続（F-70・issue #105。再起動で「まだありません」に戻さない）のテスト。
import Foundation
import TestSupport
import Testing
import VDCore
import VDDevice

@testable import VoiceDockApp

@MainActor
@Suite("AppModel の最終接続")
struct AppModelLastConnectedTests {
    static let t = Instant(epochMillis: 1_787_955_153_000)

    /// 接続中の観測（LiveServices と同じく lastConnectedAt = completedAt）
    static func connected(at: Instant) -> AppSnapshot {
        var s = AppModelTests.present()
        s.timeZone = "Asia/Tokyo"
        s.device = LastConnectedTests.snapshot(at: at, ids: ["DJIMIC3"])
        s.lastConnectedAt = at
        return s
    }

    /// 切れた後の観測（lastConnectedAt は前回の値を引き継いだもの）
    static func disconnected(last: Instant?) -> AppSnapshot {
        var s = AppModelTests.present()
        s.timeZone = "Asia/Tokyo"
        s.device = LastConnectedTests.snapshot(at: t.adding(seconds: 3_600), ids: [])
        s.lastConnectedAt = last
        return s
    }

    static func saved(_ fake: FakeServices) -> [Instant?] { fake.savedStates.map(\.lastConnectedAt) }

    static func store(_ tmp: TempDirectory) -> UIStateStore {
        UIStateStore(url: tmp.url.appendingPathComponent("ui-state.json", isDirectory: false))
    }

    @Test("再起動: 前の起動が書いた最終接続を、新しい AppModel が表示する")
    func restartShowsPreviousLastConnected() async throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let store = Self.store(tmp)
        // 1 回目の起動: DJIMIC3 を観測してから抜く（最終接続は read が決める）
        let fake1 = FakeServices(Self.connected(at: Self.t), uiStore: store)
        let model1 = AppModelTests.makeModel(fake1)
        await model1.refresh()
        #expect(model1.lastConnectedLine == "接続中（DJIMIC3）")
        let gone = Self.disconnected(last: nil)
        fake1.set(gone)
        await model1.refresh()
        #expect(model1.lastConnectedLine == "2026-08-29 07:12")
        model1.stop()
        // 2 回目の起動: デバイスは無く、メモリは空。ファイルから前回の最終接続を出す
        let fake2 = FakeServices(gone, uiStore: store)
        let model2 = AppModelTests.makeModel(fake2)
        #expect(model2.lastConnectedLine == "まだありません")
        await model2.refresh()
        #expect(fake2.lastConnectedSeen == [nil])
        #expect(model2.snapshot.lastConnectedAt == Self.t)
        #expect(model2.lastConnectedLine == "2026-08-29 07:12")
        // 読んだだけの起動は書き直さない
        #expect(fake2.savedStates.isEmpty)
    }

    @Test("一度も接続していなければ書かず「まだありません」")
    func neverConnectedWritesNothing() async throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let store = Self.store(tmp)
        let fake = FakeServices(Self.disconnected(last: nil), uiStore: store)
        let model = AppModelTests.makeModel(fake)
        await model.refresh()
        await model.refresh()
        #expect(model.lastConnectedLine == "まだありません")
        #expect(fake.savedStates.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.url.path(percentEncoded: false)))
    }

    @Test("接続中は「接続中（名前）」を出し、観測したらすぐ書く")
    func connectedShowsNameAndWrites() async {
        let fake = FakeServices(Self.connected(at: Self.t))
        let model = AppModelTests.makeModel(fake)
        await model.refresh()
        #expect(model.lastConnectedLine == "接続中（DJIMIC3）")
        #expect(fake.savedStates == [UIState(schema: 1, loginItemDecided: false, lastConnectedAt: Self.t)])
        #expect(model.snapshot.uiState.lastConnectedAt == Self.t)
    }

    @Test("接続中の書き込みは 60 秒に 1 回まで。切れたら最後の値を 1 回だけ書く")
    func writesAreThrottled() async {
        let fake = FakeServices(Self.connected(at: Self.t))
        let model = AppModelTests.makeModel(fake)
        await model.refresh()
        // 走査のたびに時刻が進むが、60 秒に満たなければ書かない
        for seconds in [5, 30, 59] {
            fake.set(Self.connected(at: Self.t.adding(seconds: seconds)))
            await model.refresh()
        }
        #expect(Self.saved(fake) == [Self.t])
        fake.set(Self.connected(at: Self.t.adding(seconds: 60)))
        await model.refresh()
        fake.set(Self.connected(at: Self.t.adding(seconds: 75)))
        await model.refresh()
        #expect(Self.saved(fake) == [Self.t, Self.t.adding(seconds: 60)])
        // 抜いたら、60 秒を待たずに最後に見た時刻を書く。その後は何度読んでも書かない
        for _ in 0..<3 {
            fake.set(Self.disconnected(last: Self.t.adding(seconds: 75)))
            await model.refresh()
        }
        #expect(Self.saved(fake) == [Self.t, Self.t.adding(seconds: 60), Self.t.adding(seconds: 75)])
    }

    @Test("ファイルと同じ値なら書かない")
    func sameAsFileWritesNothing() async {
        var s = Self.disconnected(last: Self.t)
        s.uiState.lastConnectedAt = Self.t
        let fake = FakeServices(s)
        let model = AppModelTests.makeModel(fake)
        await model.refresh()
        #expect(fake.savedStates.isEmpty)
    }

    @Test("書けなくても同じ値を書き直し続けず、表示と「今はしない」の失敗表示は変えない")
    func saveFailureDoesNotRetrySameValue() async {
        let fake = FakeServices(Self.disconnected(last: Self.t))
        fake.setSaveResult(false)
        let model = AppModelTests.makeModel(fake)
        for _ in 0..<3 { await model.refresh() }
        #expect(Self.saved(fake) == [Self.t])
        #expect(model.lastConnectedLine == "2026-08-29 07:12")
        #expect(model.uiStateSaveFailed == false)
        #expect(model.snapshot.uiState.lastConnectedAt == nil)
    }

    @Test("「今はしない」の記録は、書いた最終接続を古い値で上書きしない")
    func loginItemDecisionKeepsLastConnected() async {
        let fake = FakeServices(Self.connected(at: Self.t))
        let model = AppModelTests.makeModel(fake)
        await model.refresh()
        await model.dismissLoginItem()
        #expect(fake.savedStates.last == UIState(schema: 1, loginItemDecided: true, lastConnectedAt: Self.t))
    }

    @Test("接続中に時計が戻ったら、戻った後の時刻を書く（等しい値だけを書き直さない）")
    func clockBackWritesEarlierValue() async {
        let fake = FakeServices(Self.connected(at: Self.t))
        let model = AppModelTests.makeModel(fake)
        await model.refresh()
        fake.set(Self.connected(at: Self.t.adding(seconds: -30)))
        await model.refresh()
        #expect(Self.saved(fake) == [Self.t])
        fake.set(Self.connected(at: Self.t.adding(seconds: -120)))
        await model.refresh()
        await model.refresh()
        #expect(Self.saved(fake) == [Self.t, Self.t.adding(seconds: -120)])
    }

    @Test("refresh が重なり、古い ui-state を読んだ read が後から終わっても「今はしない」は消えない")
    func overlappingRefreshKeepsLoginItemDecided() async throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let store = Self.store(tmp)
        // 周期の read: DJIMIC3 を観測し、「今はしない」を書く前のファイル（無い = loginItemDecided false）を読んで止まる
        let fake = FakeServices(Self.connected(at: Self.t), uiStore: store)
        let model = AppModelTests.makeModel(fake)
        fake.holdNextReads(1)
        let periodic = Task { await model.refresh() }
        #expect(await AppModelTests.waitUntil { fake.heldReadCount == 1 })
        // 止まっている間に「今はしない」を押す（その後の refresh は抜いた後の観測を読む）
        fake.set(Self.disconnected(last: nil))
        await model.dismissLoginItem()
        #expect(store.load().loginItemDecided == true)
        // 古い read が終わり、最終接続を書く。そのとき「今はしない」を false で上書きしない
        fake.releaseReads()
        await periodic.value
        let file = store.load()
        #expect(file.lastConnectedAt == Self.t)
        #expect(file.loginItemDecided == true)
    }

    @Test("古い read が後から終わった後の「今はしない」は、この起動で書いた最終接続を消さない")
    func loginItemAfterStaleReadKeepsLastConnected() async throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let store = Self.store(tmp)
        // 周期の read: まだ何も観測していない観測を読んで止まる
        let fake = FakeServices(Self.disconnected(last: nil), uiStore: store)
        let model = AppModelTests.makeModel(fake)
        fake.holdNextReads(1)
        let periodic = Task { await model.refresh() }
        #expect(await AppModelTests.waitUntil { fake.heldReadCount == 1 })
        // 止まっている間に DJIMIC3 を観測し、最終接続を書く
        fake.set(Self.connected(at: Self.t))
        await model.refresh()
        #expect(store.load().lastConnectedAt == Self.t)
        // 古い read が終わり、snapshot は最終接続の無い値に戻る
        fake.set(Self.disconnected(last: nil))
        fake.releaseReads()
        await periodic.value
        #expect(model.snapshot.uiState.lastConnectedAt == nil)
        // その後の「今はしない」は、この起動で書いた最終接続を残す
        await model.dismissLoginItem()
        let file = store.load()
        #expect(file.loginItemDecided == true)
        #expect(file.lastConnectedAt == Self.t)
    }
}
