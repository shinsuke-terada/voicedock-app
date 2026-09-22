// AppModel の「今すぐ要約」の口のテスト（PLAN §5.4・§8.12 の 1。F-66）。ビューは作らない。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDPipeline

@testable import VoiceDockApp

@MainActor
@Suite("AppModel+SummarizeNow")
struct AppModelSummarizeNowTests {
    static let fixed = Instant(epochMillis: 1_756_000_000_000)
    static let layout = HomeLayout(root: URL(fileURLWithPath: "/tmp/voicedock-f66-layout", isDirectory: true))

    static func makeFake() -> FakeServices {
        var s = AppSnapshot(now: fixed)
        s.configPresent = true
        return FakeServices(s)
    }

    static func makeModel(_ fake: FakeServices) -> AppModel {
        AppModel(
            services: fake, openFinder: FakeFinder(), layout: layout, catalog: TestCatalogs.minimal,
            chooser: FakeFolderChooser(nil), fileChooser: FakeFileChooser(nil), presentModal: { $0() },
            sleeper: RecordingSleeper(), now: fixed, quit: {})
    }

    static func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<5_000 {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    /// enqueue に入った仕事から今すぐ要約の reply を取り出す（別の仕事なら nil）
    static func reply(_ job: WorkerJob?) -> (@Sendable (Result<Int, SummarizeNowFailure>) -> Void)? {
        switch job {
        case .summarizeNow(let reply): reply
        case .llmProbe, .backlog, .resolveAbsent, nil: nil
        }
    }

    @Test("押したら enqueue に .summarizeNow が 1 回入り、返事を待つ間は running")
    func pressEnqueuesOneJob() async {
        let fake = Self.makeFake()
        let model = Self.makeModel(fake)
        #expect(model.summarizeNow == .idle)
        #expect(model.summarizeNowNotice == nil)
        await model.requestSummarizeNow()
        #expect(fake.jobs.count == 1)
        #expect(Self.reply(fake.jobs.first) != nil)
        #expect(model.summarizeNow == .running)
        #expect(model.summarizeNowNotice == nil)
    }

    @Test("成功で n > 0 なら「n 日分を要約します」")
    func successWithDaysShowsCount() async throws {
        let fake = Self.makeFake()
        let model = Self.makeModel(fake)
        await model.requestSummarizeNow()
        let reply = try #require(Self.reply(fake.jobs.first))
        reply(.success(2))
        #expect(await Self.waitUntil { model.summarizeNow == .succeeded(2) })
        #expect(model.summarizeNowNotice == "2 日分を要約します")
    }

    @Test("成功で 0 なら「未要約の録音はありません」（TEST-28）")
    func successWithZeroShowsNothingToDo() async throws {
        let fake = Self.makeFake()
        let model = Self.makeModel(fake)
        await model.requestSummarizeNow()
        let reply = try #require(Self.reply(fake.jobs.first))
        reply(.success(0))
        #expect(await Self.waitUntil { model.summarizeNow == .succeeded(0) })
        #expect(model.summarizeNowNotice == "未要約の録音はありません")
    }

    @Test("失敗なら failure.message をそのまま出す")
    func failureShowsMessageVerbatim() async throws {
        let fake = Self.makeFake()
        let model = Self.makeModel(fake)
        await model.requestSummarizeNow()
        let reply = try #require(Self.reply(fake.jobs.first))
        reply(.failure(SummarizeNowFailure(message: "LLM が未選択")))
        #expect(await Self.waitUntil { model.summarizeNow == .failed("LLM が未選択") })
        #expect(model.summarizeNowNotice == "LLM が未選択")
    }

    @Test("実行中は二重に入らない（返事の後はもう一度押せる）")
    func pressWhileRunningIsIgnored() async throws {
        let fake = Self.makeFake()
        let model = Self.makeModel(fake)
        await model.requestSummarizeNow()
        await model.requestSummarizeNow()
        await model.requestSummarizeNow()
        #expect(fake.jobs.count == 1)
        let reply = try #require(Self.reply(fake.jobs.first))
        reply(.success(1))
        #expect(await Self.waitUntil { model.summarizeNow == .succeeded(1) })
        await model.requestSummarizeNow()
        #expect(fake.jobs.count == 2)
        #expect(model.summarizeNow == .running)
    }

    @Test("閉じた後に届いた返事は捨てる")
    func lateReplyAfterCloseIsDropped() async throws {
        let fake = Self.makeFake()
        let model = Self.makeModel(fake)
        await model.requestSummarizeNow()
        model.panelDidClose()
        #expect(model.summarizeNow == .idle)
        let reply = try #require(Self.reply(fake.jobs.first))
        reply(.success(3))
        for _ in 0..<50 { await Task.yield() }
        #expect(model.summarizeNow == .idle)
        #expect(model.summarizeNowNotice == nil)
    }

    @Test("閉じて押し直した後に届いた古い返事は捨て、新しい返事だけを出す")
    func staleReplyAfterReopenIsDropped() async throws {
        let fake = Self.makeFake()
        let model = Self.makeModel(fake)
        await model.requestSummarizeNow()
        model.panelDidClose()
        await model.requestSummarizeNow()
        #expect(fake.jobs.count == 2)
        let old = try #require(Self.reply(fake.jobs.first))
        old(.success(5))
        for _ in 0..<50 { await Task.yield() }
        #expect(model.summarizeNow == .running)
        let fresh = try #require(Self.reply(fake.jobs.last))
        fresh(.success(0))
        #expect(await Self.waitUntil { model.summarizeNow == .succeeded(0) })
    }

    @Test("通知は出したときの状態のままなら消え、別の状態を出していたときの消去は効かない")
    func dismissOnlyClearsTheShownNotice() async throws {
        let fake = Self.makeFake()
        let model = Self.makeModel(fake)
        await model.requestSummarizeNow()
        // 実行中は消さない
        model.dismissSummarizeNowNotice(.running)
        #expect(model.summarizeNow == .running)
        let reply = try #require(Self.reply(fake.jobs.first))
        reply(.success(2))
        #expect(await Self.waitUntil { model.summarizeNow == .succeeded(2) })
        model.dismissSummarizeNowNotice(.succeeded(1))
        #expect(model.summarizeNow == .succeeded(2))
        model.dismissSummarizeNowNotice(.succeeded(2))
        #expect(model.summarizeNow == .idle)
        #expect(model.summarizeNowNotice == nil)
    }

    @Test("通知を出しておく目安は 4 秒")
    func noticeSecondsIsFixed() {
        #expect(AppModel.summarizeNowNoticeSeconds == 4)
    }
}
