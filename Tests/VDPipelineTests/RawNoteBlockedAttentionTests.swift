// 書き直すと本文が消えるので Raw ノートを書かずに止めた Session を要対応で知らせる（F-75。PLAN §8.11。issue #115）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDNotes

@testable import VDPipeline
@testable import VDStore

@Suite("AttentionEvaluator（F-75）", .serialized, .timeLimit(.minutes(1)))
struct RawNoteBlockedAttentionTests {
    typealias Step = RawNoteStepTests
    static let key = Step.key
    static let otherKey = "DJIMIC3:20260829#2"
    /// D2 の失敗の error_message（逐語。PLAN §8.6）
    static let lostMessage =
        "書き直すと Raw ノートから本文が消える Part があります（1 本）: " + Step.partkeyA
        + "。文字起こしを読めません: transcripts/parts/a5d046dce76cfedc.json"

    /// AppServices と同じ読み方（ReadOnlyStore の FAILED の全件）で数える（PipelineWorld の DB は tmp の直下）
    static func count(_ w: PipelineWorld) throws -> Int {
        let ro = try #require(ReadOnlyStore.open(url: w.tmp.url.appendingPathComponent("voicedock.sqlite")))
        return AttentionEvaluator.rawNoteBlockedSessions(try ro.failedParts(limit: Int.max).rows)
    }

    /// A を Raw に載せて COMPLETED にし、A の transcript を消してから B で書き直させる（B は D2 で FAILED）。B を返す
    static func blockedWorld() async throws -> (PipelineWorld, a: String, b: String, transcriptA: Data) {
        let (w, a) = try await Step.world()
        #expect(try await Step.ensure(w, a))
        try w.forcePart(a, status: .completed, sessionKey: Self.key)
        let url = w.layout.transcript(slug: KeySlug.of(a))
        let saved = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        let b = try w.addPart(PipelineFixtures.partB, status: .transcribed)
        #expect(try await Step.ensure(w, b) == false)
        #expect(try w.part(b).errorMessage == Self.lostMessage)
        return (w, a, b, saved)
    }

    static func requeue(_ w: PipelineWorld, _ pk: String) async throws {
        #expect(
            try Requeue(ctx: try await w.context()).resumeFailed(
                entity: .recording, key: pk, resetRetry: true, detail: "requeue"))
    }

    /// FAILED にして error_code・error_message を書く
    static func fail(_ w: PipelineWorld, _ pk: String, _ code: ErrorCode, _ message: String) throws {
        try w.forcePart(pk, status: .failed, sessionKey: try w.part(pk).sessionKey)
        try w.store.updateRecording(pk, [.errorCode(code), .errorMessage(message)])
    }

    @Test("F-75 本文を守って書かなかった Part が居る Session を要対応に数える")
    func blockedSessionIsCounted() async throws {
        let (w, _, _, _) = try await Self.blockedWorld()
        #expect(try Self.count(w) == 1)
        var input = AttentionInput(now: Instant(epochMillis: 0))
        input.configPresent = true
        input.rawNoteBlocked = try Self.count(w)
        let items = AttentionEvaluator.items(input)
        #expect(items == [.rawNoteBlocked(1)])
        #expect(items.first?.actions == [.openDetails])
    }

    @Test("F-75 transcript を戻して再試行し RAW_SAVED になったら数えない")
    func restoredTranscriptClears() async throws {
        let (w, a, b, saved) = try await Self.blockedWorld()
        try AtomicFile.write(saved, to: w.layout.transcript(slug: KeySlug.of(a)))
        try await Self.requeue(w, b)
        #expect(try await Step.ensure(w, b))
        #expect(try w.part(b).status == .rawSaved)
        #expect(try Self.count(w) == 0)
    }

    @Test("F-75 Raw ノートの名前を変えて再試行すれば新しく書かれ、古い本文は残り、数えない")
    func renamedNoteClears() async throws {
        let (w, a, b, _) = try await Self.blockedWorld()
        let old = w.vaultURL.appendingPathComponent(Step.rawRel)
        let renamed = w.vaultURL.appendingPathComponent("Daily/Voice/Raw/20260829/2026-08-29 raw（古い）.md")
        let before = try Data(contentsOf: old)
        try FileManager.default.moveItem(at: old, to: renamed)
        try await Self.requeue(w, b)
        #expect(try await Step.ensure(w, b))
        #expect(try w.part(b).status == .rawSaved)
        #expect(try Data(contentsOf: renamed) == before)
        let text = try w.noteText(Step.rawRel)
        #expect(text.contains("  - \"" + b + "\"\n"))
        #expect(!text.contains(a))
        #expect(try Self.count(w) == 0)
    }

    @Test("F-75 ほかの FAILED（一時的な失敗・トリガが載らない失敗）と FAILED でない Part は数えない")
    func otherFailuresAreNotCounted() async throws {
        let (w, a) = try await Step.world()
        let b = try w.addPart(PipelineFixtures.partB, status: .transcribed)
        let c = try w.addPart(PipelineFixtures.partC, status: .transcribed)
        try Self.fail(w, a, .obsidianRawWriteFailed, "文字起こしを読めません: transcripts/parts/a5d046dce76cfedc.json")
        try Self.fail(w, b, .obsidianRawWriteFailed, "同名ファイルが多すぎます: 2026-08-29 raw.md")
        try Self.fail(w, c, .whisperFailed, Self.lostMessage)
        #expect(try Self.count(w) == 0)
        // 同じ文言でも FAILED でなければ数えない（再試行で RAW_WRITING に戻った間）。
        // ReadOnlyStore.failedParts は FAILED だけを返すので、行を直接渡して判定そのものを確かめる
        try Self.fail(w, a, .obsidianRawWriteFailed, Self.lostMessage)
        #expect(try Self.count(w) == 1)
        try w.forcePart(a, status: .rawWriting, sessionKey: Self.key)
        let stale = try w.part(a)
        #expect(stale.errorMessage == Self.lostMessage)
        #expect(AttentionEvaluator.rawNoteBlockedSessions([stale]) == 0)
        #expect(try Self.count(w) == 0)
    }

    @Test("F-75 数えるのは Session の数（同じ Session の 2 本は 1 件、別の Session は別に数える）")
    func countsSessions() async throws {
        let (w, a) = try await Step.world()
        let b = try w.addPart(PipelineFixtures.partB, status: .transcribed)
        try Self.fail(w, a, .obsidianRawWriteFailed, Self.lostMessage)
        try Self.fail(w, b, .obsidianRawWriteFailed, Self.lostMessage)
        #expect(try Self.count(w) == 1)
        try w.addSession(key: Self.otherKey, day: "2026-08-29", status: .ready)
        let c = try w.addPart(PipelineFixtures.partC, status: .transcribed, sessionKey: Self.otherKey)
        try Self.fail(w, c, .obsidianRawWriteFailed, Self.lostMessage)
        #expect(try Self.count(w) == 2)
    }

    @Test("F-75 FAILED が無ければ数えず、要対応に出さない（空の入力）")
    func emptyIsQuiet() async throws {
        #expect(AttentionEvaluator.rawNoteBlockedSessions([]) == 0)
        var input = AttentionInput(now: Instant(epochMillis: 0))
        input.configPresent = true
        #expect(AttentionEvaluator.items(input).isEmpty)
        let (w, _) = try await Step.world()
        #expect(try Self.count(w) == 0)
    }

    @Test("F-75 Daily は本文を守って止めた FAILED に「自動で再試行されます」を出さない")
    func dailyWarnsWithoutRetryPromise() async throws {
        var failed = ""
        let (w, t) = try await DailyNoteStepTests.world(before: { w in
            failed = try w.addPart(PipelineFixtures.partB, status: .failed, segments: nil)
            try w.store.updateRecording(failed, [.errorCode(.obsidianRawWriteFailed), .errorMessage(Self.lostMessage)])
        })
        #expect(try await DailyNoteStepTests.ensure(w, t))
        let text = try w.noteText(DailyNoteStepTests.dailyRel)
        #expect(
            text.contains(
                "\n> ⚠ この日の録音のうち 1 本は Raw ノートに書けませんでした（書き直すと、文字起こしを読めなくなった録音の本文が Raw ノートから消えるため）。"
                    + "自動では直りません。VoiceDock の要対応を確かめてください。\n"))
        #expect(!text.contains("処理できませんでした"))
        #expect(text.contains("voicedock_failed_parts:\n  - \"" + failed + "\"\n"))
    }
}
