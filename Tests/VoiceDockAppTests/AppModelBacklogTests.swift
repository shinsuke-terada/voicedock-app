// AppModel の後追いの状態（PLAN §8.9.9。T-41 §6.4）。ビューは作らない。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDPipeline

@testable import VoiceDockApp

@MainActor
@Suite("AppModel+Backlog")
struct AppModelBacklogTests {
    static let fixed = Instant(epochMillis: 1_756_000_000_000)
    static let layout = HomeLayout(root: URL(fileURLWithPath: "/tmp/voicedock-t41-layout", isDirectory: true))
    static let plan = BacklogPlan(eligible: ["a"], skipped: [BacklogSkip(partkey: "b", reason: "not_deletable")])

    static func makeModel(_ fake: FakeServices) -> AppModel {
        AppModel(
            services: fake, openFinder: FakeFinder(), layout: layout, catalog: TestCatalogs.minimal,
            chooser: FakeFolderChooser(nil), fileChooser: FakeFileChooser(nil), presentModal: { $0() },
            sleeper: RecordingSleeper(), now: fixed, quit: {})
    }

    static func fake() -> FakeServices {
        var s = AppSnapshot(now: fixed)
        s.configPresent = true
        return FakeServices(s)
    }

    static func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<5_000 {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    @Test("過去分: preview → execute → done の順に移り、閉じると idle")
    func previewExecuteDone() async throws {
        let fake = Self.fake()
        let model = Self.makeModel(fake)
        #expect(model.backlogState == .idle)
        model.previewBacklog(.backlog)
        #expect(model.backlogState == .working(.backlog))
        #expect(model.backlogExecuting == false)
        #expect(await Self.waitUntil { fake.jobs.count == 1 })
        guard case .backlog(.preview(let previewReply)) = try #require(fake.jobs.first) else {
            Issue.record("過去分の preview の仕事ではない")
            return
        }
        previewReply(.success(Self.plan))
        #expect(await Self.waitUntil { model.backlogState == .preview(.backlog, Self.plan) })
        model.executeBacklog(.backlog)
        #expect(model.backlogState == .working(.backlog))
        #expect(model.backlogExecuting == true)
        #expect(await Self.waitUntil { fake.jobs.count == 2 })
        guard case .backlog(.execute(let executeReply)) = try #require(fake.jobs.last) else {
            Issue.record("過去分の execute の仕事ではない")
            return
        }
        let execution = BacklogExecution(plan: Self.plan, done: 1)
        executeReply(.success(execution))
        #expect(await Self.waitUntil { model.backlogState == .done(.backlog, execution) })
        model.dismissBacklog()
        #expect(model.backlogState == .idle)
        #expect(model.backlogExecuting == false)
    }

    @Test("手動で消した分は resolveAbsent の仕事を入れ、失敗は failed")
    func resolveAbsentFailure() async throws {
        let fake = Self.fake()
        let model = Self.makeModel(fake)
        model.previewBacklog(.resolveAbsent)
        #expect(await Self.waitUntil { fake.jobs.count == 1 })
        guard case .resolveAbsent(.preview(let reply)) = try #require(fake.jobs.first) else {
            Issue.record("手動で消した分の preview の仕事ではない")
            return
        }
        reply(.failure(BacklogFailure(message: "x")))
        #expect(await Self.waitUntil { model.backlogState == .failed(.resolveAbsent, "x") })
    }

    @Test("kind が違う返事と、閉じた後の返事は捨てる")
    func mismatchedRepliesAreDropped() async throws {
        let fake = Self.fake()
        let model = Self.makeModel(fake)
        model.previewBacklog(.backlog)
        model.receive(.resolveAbsent, .success(Self.plan))
        #expect(model.backlogState == .working(.backlog))
        model.receive(.resolveAbsent, .success(BacklogExecution(plan: Self.plan, done: 1)))
        #expect(model.backlogState == .working(.backlog))
        model.dismissBacklog()
        model.receive(.backlog, .success(Self.plan))
        #expect(model.backlogState == .idle)
    }

    @Test("working の間の押下と、preview でないときの実行は何もしない（空の状態から。TEST-28）")
    func pressesOutsideTheirStateAreIgnored() async throws {
        let fake = Self.fake()
        let model = Self.makeModel(fake)
        model.executeBacklog(.backlog)
        #expect(model.backlogState == .idle)
        model.previewBacklog(.backlog)
        model.previewBacklog(.resolveAbsent)
        #expect(model.backlogState == .working(.backlog))
        #expect(await Self.waitUntil { fake.jobs.count == 1 })
        for _ in 0..<50 { await Task.yield() }
        #expect(fake.jobs.count == 1)
    }
}
