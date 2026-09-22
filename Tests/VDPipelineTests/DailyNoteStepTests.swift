// Daily ノートの工程のテスト（T-29 §6.2。PLAN §5.6 末尾・§8.6〜§8.8。voicedock test_session_analysis・test_session_resume）。
import CryptoKit
import Foundation
import GRDB
import TestSupport
import Testing
import VDContract
import VDCore
import VDNotes

@testable import VDPipeline
@testable import VDStore

@Suite("DailyNoteStep", .serialized, .timeLimit(.minutes(1)))
struct DailyNoteStepTests {
    static let key = PipelineFixtures.vaultSessionKey
    static let slug = KeySlug.of(PipelineFixtures.vaultSessionKey)
    static let dailyRel = "Daily/Voice/Wiki/20260829/2026-08-29 Voice.md"
    static let daily2Rel = "Daily/Voice/Wiki/20260829/2026-08-29 Voice (2).md"
    static let dailyFolder = "Daily/Voice/Wiki/20260829"
    static let rawRel = "Daily/Voice/Raw/20260829/2026-08-29 raw.md"

    /// 期待 D1（§6.6）
    static let expectedD1 = """
        ---
        type: "voice-daily"
        voicedock_session_key: "DJIMIC3:20260829"
        voicedock_recording_keys:
          - "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
        voicedock_failed_parts: []
        voicedock_skipped_parts: []
        date: "2026-08-29"
        recorded: "00:00:02"
        parts: 1
        blocks: 1
        status: "processed"
        tags:
          - "voice"
          - "voicedock"
        ---

        # 開発の一日

        ## Summary

        削除条件を整理した。

        ## Timeline

        ### 07:12–07:12

        - 削除条件を整理した。

        ## Key Points

        - 論理式に落とした

        ## Tasks

        - [ ] ND テストを書く

        ## Sources

        - [[2026-08-29 raw]]

        ## Links

        - [[2026-08-29]]
        - [[2026-08-28 Voice]]
        - [[2026-08-30 Voice]]

        """

    /// 既定の準備: installLLM・Vault・MERGED の Session・RAW_SAVED の Part A・raw_output_path。
    /// before は ensureAnalysis の前に行う追加の準備（除外 Part など）。ensureAnalysis で ANALYZED にして統合結果を返す。
    static func world(
        vault: Bool = true, marker: Bool = true, rawOutputPath: String = rawRel,
        before: (PipelineWorld) throws -> Void = { _ in }
    ) async throws -> (PipelineWorld, SessionTranscript) {
        let w = try await PipelineWorld.make(chat: FakeChatTransport(responses: [.content(PipelineFixtures.analysis)]))
        try await w.installLLM()
        if vault { try await w.installVault(marker: marker) }
        try w.addSession(key: key, day: "2026-08-29", status: .merged)
        try w.addPart(PipelineFixtures.partA, status: .rawSaved)
        try w.store.updateSession(key, [.rawOutputPath(rawOutputPath)])
        try before(w)
        let steps = SessionSteps(ctx: try await w.context())
        let t = try #require(try steps.buildSessionTranscript(key))
        #expect(await steps.ensureAnalysis(key, t))
        #expect(try w.session(key).status == .analyzed)
        return (w, t)
    }

    static func ensure(_ w: PipelineWorld, _ t: SessionTranscript, ctx: TickContext? = nil) async throws -> Bool {
        let c: TickContext
        if let ctx { c = ctx } else { c = try await w.context() }
        return await SessionSteps(ctx: c).ensureDailyNote(key, t)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func timelineURL(_ w: PipelineWorld) -> URL { w.layout.timelineJSON(sessionSlug: slug) }

    /// 保存済みの Timeline（Part A の 07:12:04〜07:12:06 の 1 Block）。
    static func timelineJSON(fingerprint: String, line: String) -> String {
        "{\n  \"schema\": 2,\n  \"transcript_sha256\": \"" + fingerprint + "\",\n  \"blocks\": [\n    {\n"
            + "      \"start_at\": \"2026-08-29T07:12:04+09:00\",\n      \"end_at\": \"2026-08-29T07:12:06+09:00\",\n"
            + "      \"lines\": [\n        \"" + line + "\"\n      ]\n    }\n  ]\n}\n"
    }

    static func write(_ w: PipelineWorld, _ rel: String, _ text: String) throws {
        let url = w.vaultURL.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFile.write(Data(text.utf8), to: url)
    }

    /// error_code を直に書く（テストだけの近道。ErrorCode に無い値も書ける）。
    static func setErrorCode(_ w: PipelineWorld, _ pk: String, _ code: String) throws {
        try w.store.pool.write { db in
            try db.execute(sql: "UPDATE recordings SET error_code = ? WHERE partkey = ?", arguments: [code, pk])
        }
    }

    // MARK: - 成功

    @Test("Daily を書いて検証し、SAVED")
    func writesVerifiedDailyNote() async throws {
        let (w, t) = try await Self.world()
        #expect(try await Self.ensure(w, t))
        let s = try w.session(Self.key)
        #expect(s.status == .saved)
        #expect(s.outputPath == Self.dailyRel)
        let data = try Data(contentsOf: w.vaultURL.appendingPathComponent(Self.dailyRel))
        #expect(s.outputSHA256 == Self.sha256Hex(data))
        #expect(data == Data(Self.expectedD1.utf8))
        let bytes = Self.expectedD1.utf8.count
        #expect(
            w.lines("obsidian_saved").contains {
                $0.hasSuffix(
                    "obsidian_saved session_key=DJIMIC3:20260829 path=\"Daily/Voice/Wiki/20260829/2026-08-29 Voice.md\" "
                        + "bytes=\(bytes)")
            })
    }

    @Test("WRITING から入っても ANALYZED→WRITING を書かない")
    func writingEntryRecordsNoPhantom() async throws {
        let (w, t) = try await Self.world()
        try w.forceSession(Self.key, status: .writing)
        func phantom() throws -> Int {
            try w.sessionEvents(Self.key).filter { $0.fromStatus == "ANALYZED" && $0.toStatus == "WRITING" }.count
        }
        let before = try phantom()
        #expect(try await Self.ensure(w, t))
        #expect(try w.session(Self.key).status == .saved)
        #expect(try phantom() == before)
    }

    // MARK: - ガードと失敗

    @Test("Vault のガードは遷移しない", arguments: [false, true])
    func guardsDoNotTransition(installed: Bool) async throws {
        let (w, t) = try await Self.world(vault: installed, marker: false)
        #expect(try await Self.ensure(w, t) == false)
        #expect(try w.session(Self.key).status == .analyzed)
        let reason = installed ? "vault_unavailable" : "vault_not_configured"
        #expect(w.lines("pipeline_paused").contains { $0.hasSuffix("pipeline_paused reason=" + reason) })
    }

    @Test("解析 JSON が読めなければ WRITING を記録してから FAILED")
    func unreadableAnalysisIsWriteFailed() async throws {
        let (w, t) = try await Self.world()
        try AtomicFile.write(Data("{".utf8), to: w.layout.analysisJSON(sessionSlug: Self.slug))
        #expect(try await Self.ensure(w, t) == false)
        let events = try w.sessionEvents(Self.key).suffix(2)
        #expect(events.map(\.fromStatus) == ["ANALYZED", "WRITING"])
        #expect(events.map(\.toStatus) == ["WRITING", "FAILED"])
        let s = try w.session(Self.key)
        #expect(s.errorCode == .obsidianWriteFailed)
        let message = "解析結果を読めません: analysis/" + Self.slug + ".json"
        #expect(s.errorMessage == message)
        #expect(
            w.lines("obsidian_failed").contains {
                $0.hasSuffix(
                    "obsidian_failed session_key=DJIMIC3:20260829 error_code=OBSIDIAN_WRITE_FAILED reason=write detail=\""
                        + message + "\"")
            })
    }

    @Test("遷移の後に Vault が消えたら OBSIDIAN_NOT_FOUND")
    func vaultLostAfterTransitionFails() async throws {
        let (w, t) = try await Self.world()
        let marker = w.vaultURL.appendingPathComponent(".obsidian", isDirectory: true)
        let assertion = RecordingSleepAssertion(onBegin: { try? FileManager.default.removeItem(at: marker) })
        #expect(try await Self.ensure(w, t, ctx: try await w.context(assertion: assertion)) == false)
        let s = try w.session(Self.key)
        #expect(s.status == .failed)
        #expect(s.errorCode == .obsidianNotFound)
        #expect(
            w.lines("obsidian_failed").contains {
                $0.contains("obsidian_failed session_key=DJIMIC3:20260829 error_code=OBSIDIAN_NOT_FOUND reason=vault ")
            })
    }

    // MARK: - Timeline

    @Test("保存済みの Timeline を使う")
    func savedTimelineIsPreferred() async throws {
        let (w, t) = try await Self.world()
        let fp = TranscriptFingerprint.of(t, zone: PipelineFixtures.zone)
        try AtomicFile.write(
            Data(Self.timelineJSON(fingerprint: fp, line: "保存済みの点").utf8), to: Self.timelineURL(w))
        #expect(try await Self.ensure(w, t))
        let text = try w.noteText(Self.dailyRel)
        #expect(text.contains("\n- 保存済みの点\n"))
        #expect(!text.contains("- 削除条件を整理した。"))
    }

    @Test("指紋の違う Timeline は使わず summary の文へ落ちる")
    func staleTimelineFallsBack() async throws {
        let (w, t) = try await Self.world()
        try AtomicFile.write(
            Data(Self.timelineJSON(fingerprint: String(repeating: "0", count: 64), line: "保存済みの点").utf8),
            to: Self.timelineURL(w))
        #expect(try await Self.ensure(w, t))
        let text = try w.noteText(Self.dailyRel)
        #expect(text.contains("\n- 削除条件を整理した。\n"))
        #expect(!text.contains("保存済みの点"))
    }

    @Test("Timeline が無ければ代替経路")
    func missingTimelineFallsBack() async throws {
        let (w, t) = try await Self.world()
        try FileManager.default.removeItem(at: Self.timelineURL(w))
        #expect(try await Self.ensure(w, t))
        #expect(try w.noteText(Self.dailyRel).contains("\n- 削除条件を整理した。\n"))
    }

    // MARK: - リンクと除外

    @Test("X-15 Sources は実際の Raw の名前")
    func sourcesPointToActualRaw() async throws {
        let (w, t) = try await Self.world(rawOutputPath: "Daily/Voice/Raw/20260829/2026-08-29 raw (2).md")
        #expect(try await Self.ensure(w, t))
        #expect(try w.noteText(Self.dailyRel).contains("\n- [[2026-08-29 raw (2)]]\n"))
    }

    @Test("タグのリンクは Vault 索引に在るものだけ", arguments: [true, false])
    func tagLinksUseTheIndex(indexed: Bool) async throws {
        let (w, t) = try await Self.world()
        var ctx = try await w.context()
        ctx.vaultIndex = indexed ? VaultIndex(names: [VaultIndex.normalize("VoiceDock")], builtAt: .zero) : nil
        #expect(try await Self.ensure(w, t, ctx: ctx))
        let text = try w.noteText(Self.dailyRel)
        #expect(text.contains("\n- [[VoiceDock]]\n") == indexed)
    }

    @Test("除外 Part は警告行に出て recording_keys に載らない（DN-7）")
    func excludedPartsAreWarnedAndNotListed() async throws {
        var failed = ""
        var skipped = ""
        let (w, t) = try await Self.world(before: { w in
            failed = try w.addPart(PipelineFixtures.partB, status: .failed, segments: nil)
            try w.store.updateRecording(failed, [.errorCode(.whisperFailed)])
            skipped = try w.addPart(PipelineFixtures.partC, status: .skipped, segments: nil)
            try w.store.updateRecording(skipped, [.errorCode(.noSpeechDetected)])
        })
        #expect(try await Self.ensure(w, t))
        #expect(try w.session(Self.key).status == .saved)
        let text = try w.noteText(Self.dailyRel)
        #expect(
            text.contains(
                "voicedock_recording_keys:\n  - \"" + PipelineFixtures.partkey + "\"\nvoicedock_failed_parts:\n  - \""
                    + failed + "\"\nvoicedock_skipped_parts:\n  - \"" + skipped + "\"\n"))
        #expect(text.contains("> ⚠ この日の録音のうち 1 本が"))
        #expect(text.contains("> この日の録音のうち 1 本を除外しました（無音）。"))
    }

    @Test("M-1 未知のエラーコードは生の文字列で警告に出る")
    func unknownErrorCodeIsShownAsRaw() async throws {
        // 理由を行に出すのは SKIPPED の警告行だけ（FAILED の行は本数だけ。T-27 DailyWarnings）
        var skipped = ""
        let (w, t) = try await Self.world(before: { w in
            skipped = try w.addPart(PipelineFixtures.partB, status: .skipped, segments: nil)
            try Self.setErrorCode(w, skipped, "FUTURE_CODE_X")
        })
        let steps = SessionSteps(ctx: try await w.context())
        let input = steps.dailyInput(
            row: try w.session(Self.key), analysis: try #require(steps.loadAnalysis(Self.key)),
            parts: try w.store.recordings(inSession: Self.key), day: try #require(LocalDate(dashed: "2026-08-29")),
            transcript: t)
        let excluded = try #require(input.excluded.first)
        #expect(input.excluded.count == 1)
        #expect(excluded.partkey == skipped)
        #expect(excluded.errorCode == nil)
        #expect(excluded.unknownCode == "FUTURE_CODE_X")
        #expect(try await Self.ensure(w, t))
        #expect(
            try w.noteText(Self.dailyRel).contains(
                "\n> ⚠ この日の録音のうち 1 本を除外しました（FUTURE_CODE_X）。自動では再試行されません。デバイスから採り直してください。\n"))
    }

    // MARK: - 既存ノート

    @Test("DB の出力パスのノートは上書きする")
    func ownDailyIsOverwritten() async throws {
        let (w, t) = try await Self.world()
        #expect(try await Self.ensure(w, t))
        try w.forceSession(Self.key, status: .analyzed)
        #expect(try await Self.ensure(w, t))
        #expect(try w.session(Self.key).outputPath == Self.dailyRel)
        let folder = w.vaultURL.appendingPathComponent(Self.dailyFolder, isDirectory: true)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) == [
                "2026-08-29 Voice.md"
            ])
    }

    @Test("他人の Daily は上書きしない")
    func foreignDailyIsNotOverwritten() async throws {
        let (w, t) = try await Self.world()
        let foreign =
            "---\ntype: \"voice-daily\"\nvoicedock_session_key: \"DJIMIC3:20260829\"\nvoicedock_recording_keys:\n"
            + "  - \"DJIMIC3/other_orig.wav\"\n---\n\n# 他人のノート\n"
        try Self.write(w, Self.dailyRel, foreign)
        #expect(try await Self.ensure(w, t))
        #expect(try w.noteText(Self.dailyRel) == foreign)
        #expect(try w.session(Self.key).outputPath == Self.daily2Rel)
        #expect(try w.noteText(Self.daily2Rel) == Self.expectedD1)
    }
}
