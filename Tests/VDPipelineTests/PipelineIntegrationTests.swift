// BWF から Daily ノートの検証までの結合テスト（T-29 §6.6）。本物の AVFoundation・本物の ProcessRunner と FakeWhisper・
// FakeChatTransport・FakeLLMServer。Vault は TempDirectory の中だけ。
// T-38 以降: 削除は既定で無効なので、SAVED の直後の削除段（PLAN §8.9.5）が Part を COMPLETED、Session を CLEANUP→COMPLETED まで進める。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDLLM
import VDNotes
import VDStore

@testable import VDPipeline

@Suite("BWF から Daily まで", .serialized, .timeLimit(.minutes(1)))
struct PipelineIntegrationTests {
    static let key = PipelineFixtures.vaultSessionKey
    static let slug = KeySlug.of(PipelineFixtures.vaultSessionKey)
    static let rawRel = "Daily/Voice/Raw/20260829/2026-08-29 raw.md"
    static let dailyRel = "Daily/Voice/Wiki/20260829/2026-08-29 Voice.md"
    static let partkeyA = "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
    static let partkeyB = "DJIMIC3/TX_MIC001_20260829_074201/TX01_MIC002_20260829_074210_orig.wav"
    /// 既定の summary の見出し（sections.summary.heading の既定）
    static let summaryHeading = "## Summary"

    /// 時計は 2026-08-30T07:00:12+09:00。whisper・LLM・Vault を置き、Part A を登録する。
    static func world(marker: Bool = true) async throws -> (PipelineWorld, Worker, String) {
        let w = try await PipelineWorld.make(
            chat: FakeChatTransport(
                responses: [.content(PipelineFixtures.analysis), .content(PipelineFixtures.analysis)]))
        try w.installWhisper()
        try await w.installLLM()
        try await w.installVault(marker: marker)
        let a = PipelineFixtures.partA
        let pk = try w.registerPart(relpath: a.relpath, startedAt: a.startedAt, seconds: a.seconds)
        let worker = w.worker()
        await worker.start()
        return (w, worker, pk)
    }

    /// DB の SHA と鍵で検証し直す。
    static func verify(_ w: PipelineWorld, _ rel: String, kind: NoteKind, sha: String?, keys: Set<String>) throws
        -> Bool
    {
        NoteVerifier.verify(
            url: w.vaultURL.appendingPathComponent(rel), kind: kind, sessionKey: key, expectedSHA256: try #require(sha),
            expectedKeys: keys, summaryHeading: summaryHeading
        ).passed
    }

    /// event 名の最初の行の位置（無ければ nil）。
    static func index(_ w: PipelineWorld, _ event: String, containing: String? = nil) -> Int? {
        w.sink.lines.firstIndex {
            ($0.contains(" " + event + " ") || $0.hasSuffix(" " + event)) && (containing.map($0.contains) ?? true)
        }
    }

    @Test("1 tick で BWF → 16 kHz → 文字起こし → Raw → 統合 → 解析 → Daily")
    func oneTickFromBWFToVerifiedDaily() async throws {
        let (w, worker, pk) = try await Self.world()
        await worker.tick()

        // Part A（SAVED の直後の削除段で RAW_SAVED→COMPLETED。T-38）
        let part = try w.part(pk)
        #expect(part.status == .completed)
        #expect(
            try w.partEvents(pk).map(\.toStatus) == [
                "DISCOVERED", "NORMALIZING", "NORMALIZED", "TRANSCRIBING", "TRANSCRIBED", "RAW_WRITING", "RAW_SAVED",
                "COMPLETED",
            ])
        let partSlug = KeySlug.of(pk)
        #expect(
            !PipelineFixtures.exists(w.layout.inboxFile(deviceID: "DJIMIC3", relpath: PipelineFixtures.partA.relpath)))
        #expect(!PipelineFixtures.exists(w.layout.normalizedAudio(slug: partSlug)))
        #expect(PipelineFixtures.exists(w.layout.transcript(slug: partSlug)))

        // Session（削除が無効なので SAVED→CLEANUP→COMPLETED。T-38）
        let s = try w.session(Self.key)
        #expect(s.status == .completed)
        let events = try w.sessionEvents(Self.key)
        #expect(
            events.map(\.toStatus) == [
                "OPEN", "OPEN", "READY", "MERGING", "MERGED", "ANALYZING", "ANALYZED", "WRITING", "SAVED", "CLEANUP",
                "COMPLETED",
            ])
        #expect(
            w.sink.lines.contains {
                $0.hasSuffix("source_delete_skipped session_key=" + Self.key + " reason=delete_source_audio_disabled")
            })
        #expect(events.count > 2 && events[1].detail == pk && events[2].detail == "stale_day")
        #expect(s.rawOutputPath == Self.rawRel)
        #expect(s.outputPath == Self.dailyRel)
        #expect(s.analysisPath == "analysis/" + Self.slug + ".json")
        #expect(s.title == "開発の一日")
        #expect(s.regeneratedCount == 0)

        // ノート
        #expect(try w.noteText(Self.rawRel) == RawNoteStepTests.expectedR1)
        #expect(try w.noteText(Self.dailyRel) == DailyNoteStepTests.expectedD1)
        #expect(try Self.verify(w, Self.rawRel, kind: .raw, sha: s.rawOutputSHA256, keys: [Self.partkeyA]))
        #expect(try Self.verify(w, Self.dailyRel, kind: .daily, sha: s.outputSHA256, keys: [Self.partkeyA]))

        // LLM
        let calls = await w.chat.calls
        #expect(calls.count == 1)
        let config = try #require(await w.configStore.current())
        let schema = AnalysisSchema(config: AnalysisConfigView(sections: config.llm.analysis.sections), kind: .final)
        let prompts = try Prompts.load(directory: w.paths.promptsDirectory)
        #expect(calls.first?.system == prompts.analyze(schema: schema, custom: ""))
        #expect(calls.first?.user == "おはようございます。\n今日の予定を確認します。")
        #expect(await w.llm.ensureCalls.count == 1)
        #expect(await w.llm.stopCount == 1)

        // 解析のファイル
        #expect(PipelineFixtures.exists(w.layout.timelineJSON(sessionSlug: Self.slug)))
        #expect(PipelineFixtures.exists(w.layout.sourceJSON(sessionSlug: Self.slug)))

        // ログの順
        let order = [
            Self.index(w, "normalize_completed"), Self.index(w, "transcription_completed"),
            Self.index(w, "raw_note_saved"),
            Self.index(w, "session_merged", containing: " parts=1 excluded=0 chars=22"),
            Self.index(w, "llm_completed", containing: " chunks=1"), Self.index(w, "obsidian_saved"),
        ]
        let found = order.compactMap { $0 }
        #expect(found.count == 6)
        #expect(found == found.sorted())
    }

    @Test("同じ日の 2 本目で Raw を書き直し、再オープン・再解析して Daily を書き直す")
    func secondPartReopensAndRewrites() async throws {
        let (w, worker, pkA) = try await Self.world()
        await worker.tick()
        #expect(try w.session(Self.key).status == .completed)
        let before = try w.sessionEvents(Self.key).count
        let b = PipelineFixtures.partB
        let pkB = try w.registerPart(relpath: b.relpath, startedAt: b.startedAt, seconds: b.seconds)
        await worker.tick()

        #expect(try w.part(pkB).status == .completed)
        #expect(try w.part(pkA).status == .completed)

        let s = try w.session(Self.key)
        #expect(s.status == .completed)
        #expect(s.regeneratedCount == 1)
        let added = Array(try w.sessionEvents(Self.key).dropFirst(before))
        #expect(
            added.map(\.toStatus) == [
                "MERGING", "MERGED", "ANALYZING", "ANALYZED", "WRITING", "SAVED", "CLEANUP", "COMPLETED",
            ])
        #expect(added.first?.detail == "reopen")
        #expect(!added.contains { $0.detail == "analysis_reused" })

        #expect(await w.chat.calls.count == 2)
        #expect(await w.llm.stopCount == 2)

        let raw = try w.noteText(Self.rawRel)
        #expect(
            raw.contains(
                "voicedock_recording_keys:\n  - \"" + Self.partkeyA + "\"\n  - \"" + Self.partkeyB + "\"\n"))
        #expect(raw.contains("\nparts: 2\n"))
        #expect(raw.contains("\n## 07:12–07:12\n"))
        #expect(raw.contains("\n## 07:42–07:42\n"))
        #expect(raw.contains("\n### 07:42:10\n"))

        #expect(s.outputPath == Self.dailyRel)
        let folder = w.vaultURL.appendingPathComponent("Daily/Voice/Wiki/20260829", isDirectory: true)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) == [
                "2026-08-29 Voice.md"
            ])
        let daily = try w.noteText(Self.dailyRel)
        #expect(
            daily.contains(
                "voicedock_recording_keys:\n  - \"" + Self.partkeyA + "\"\n  - \"" + Self.partkeyB + "\"\n"))
        #expect(daily.contains("\nrecorded: \"00:00:05\"\n"))
        #expect(daily.contains("\nparts: 2\n"))
        #expect(daily.contains("\nblocks: 1\n"))
        #expect(daily.contains("\n### 07:12–07:42\n"))
        #expect(
            try Self.verify(w, Self.dailyRel, kind: .daily, sha: s.outputSHA256, keys: [Self.partkeyA, Self.partkeyB]))
    }

    @Test("Vault の目印が無い間は待ち、戻れば続きから進む")
    func missingVaultPausesThenResumes() async throws {
        let (w, worker, pk) = try await Self.world(marker: false)
        await worker.tick()
        #expect(try w.part(pk).status == .transcribed)
        #expect(try w.session(Self.key).status == .ready)
        #expect(w.lines("pipeline_paused").contains { $0.hasSuffix("pipeline_paused reason=vault_unavailable") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: w.vaultPath).isEmpty)

        try FileManager.default.createDirectory(
            at: w.vaultURL.appendingPathComponent(".obsidian", isDirectory: true), withIntermediateDirectories: true)
        await worker.tick()
        #expect(try w.part(pk).status == .completed)
        #expect(try w.session(Self.key).status == .completed)
        #expect(w.lines("pipeline_resumed").contains { $0.hasSuffix("pipeline_resumed reason=vault_unavailable") })
    }
}
