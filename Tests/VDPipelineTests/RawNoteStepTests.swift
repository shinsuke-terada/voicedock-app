// Raw ノートの工程のテスト（T-29 §6.1。PLAN §8.6〜§8.8。voicedock test_part_resume・test_session_reopen）。
import CryptoKit
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDNotes
import VDStore

@testable import VDPipeline

@Suite("RawNoteStep", .serialized, .timeLimit(.minutes(1)))
struct RawNoteStepTests {
    static let key = PipelineFixtures.vaultSessionKey
    static let rawRel = "Daily/Voice/Raw/20260829/2026-08-29 raw.md"
    static let raw2Rel = "Daily/Voice/Raw/20260829/2026-08-29 raw (2).md"
    static let rawFolder = "Daily/Voice/Raw/20260829"
    static let partkeyA = "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"

    /// 期待 R1（§6.6）
    static let expectedR1 = """
        ---
        type: "voice-raw"
        voicedock_session_key: "DJIMIC3:20260829"
        voicedock_recording_keys:
          - "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
        date: "2026-08-29"
        parts: 1
        source: "DJI Mic 3"
        ---

        # 2026-08-29 の文字起こし（生データ）

        > 自動文字起こしの生データ。未編集。

        ## 07:12–07:12

        ### 07:12:04

        おはようございます。 今日の予定を確認します。

        """

    /// 既定の準備: Vault（marker で目印）、READY の Session、TRANSCRIBED の Part A。
    static func world(
        vault: Bool = true, marker: Bool = true, status: PartStatus = .transcribed,
        configure: (inout AppConfig) -> Void = { _ in }, inbox: Bool = false
    ) async throws -> (PipelineWorld, String) {
        let w = try await PipelineWorld.make(configure: configure)
        if vault { try await w.installVault(marker: marker) }
        try w.addSession(key: key, day: "2026-08-29", status: .ready)
        let pk = try w.addPart(PipelineFixtures.partA, status: status, inbox: inbox)
        return (w, pk)
    }

    static func ensure(_ w: PipelineWorld, _ pk: String, ctx: TickContext? = nil) async throws -> Bool {
        let c: TickContext
        if let ctx { c = ctx } else { c = try await w.context() }
        return await PartSteps(ctx: c).ensureRawNote(try w.part(pk))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func exists(_ w: PipelineWorld, _ rel: String) -> Bool {
        PipelineFixtures.exists(w.vaultURL.appendingPathComponent(rel))
    }

    /// 同じ session_key で DB に無い鍵を持つ Raw ノート。
    static func foreignNote() -> String {
        "---\ntype: \"voice-raw\"\nvoicedock_session_key: \"DJIMIC3:20260829\"\nvoicedock_recording_keys:\n"
            + "  - \"DJIMIC3/other_orig.wav\"\n---\n\n# 他人のノート\n"
    }

    static func write(_ w: PipelineWorld, _ rel: String, _ text: String) throws {
        let url = w.vaultURL.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFile.write(Data(text.utf8), to: url)
    }

    // MARK: - 成功

    @Test("Raw を書いて検証し、DB の後に RAW_SAVED")
    func writesVerifiedRawNote() async throws {
        let (w, pk) = try await Self.world()
        #expect(try await Self.ensure(w, pk))
        #expect(try w.part(pk).status == .rawSaved)
        let s = try w.session(Self.key)
        #expect(s.rawOutputPath == Self.rawRel)
        let data = try Data(contentsOf: w.vaultURL.appendingPathComponent(Self.rawRel))
        #expect(s.rawOutputSHA256 == Self.sha256Hex(data))
        #expect(data == Data(Self.expectedR1.utf8))
        let bytes = Self.expectedR1.utf8.count
        #expect(
            w.lines("raw_note_saved").contains {
                $0.hasSuffix("raw_note_saved session_key=DJIMIC3:20260829 parts=1 bytes=\(bytes)")
            })
    }

    @Test("RAW_WRITING から入っても遷移を記録しない")
    func rawWritingEntryRecordsNoPhantom() async throws {
        let (w, pk) = try await Self.world(status: .rawWriting)
        #expect(try await Self.ensure(w, pk))
        #expect(try w.part(pk).status == .rawSaved)
        #expect(
            try !w.partEvents(pk).contains { $0.fromStatus == "TRANSCRIBED" && $0.toStatus == "RAW_WRITING" })
    }

    @Test("載せる Part は RawNoteMembership（読めない transcript は載せない）")
    func membersUseTheSharedFunction() async throws {
        let (w, pk) = try await Self.world()
        let b = try w.addPart(PipelineFixtures.partB, status: .rawSaved, segments: nil)
        let c = try w.addPart(PipelineFixtures.partC, status: .transcribing)
        #expect(try await Self.ensure(w, pk))
        #expect(try w.part(pk).status == .rawSaved)
        let text = try w.noteText(Self.rawRel)
        #expect(text.contains("  - \"" + Self.partkeyA + "\"\n"))
        #expect(!text.contains(b))
        #expect(!text.contains(c))
        #expect(text.contains("parts: 1\n"))
    }

    @Test("載せる Part が無ければ何もしない")
    func noMembersStaysTranscribed() async throws {
        let (w, pk) = try await Self.world()
        try FileManager.default.removeItem(at: w.layout.transcript(slug: KeySlug.of(pk)))
        let before = try w.eventCount(parts: [pk], sessions: [Self.key])
        #expect(try await Self.ensure(w, pk) == false)
        #expect(try w.part(pk).status == .transcribed)
        #expect(try w.eventCount(parts: [pk], sessions: [Self.key]) == before)
    }

    // MARK: - ガードと Vault の喪失

    @Test("Vault 未設定なら遷移せずに待つ")
    func vaultNotConfiguredIsAGuard() async throws {
        let (w, pk) = try await Self.world(vault: false)
        #expect(try await Self.ensure(w, pk) == false)
        #expect(try w.part(pk).status == .transcribed)
        #expect(w.lines("pipeline_paused").contains { $0.hasSuffix("pipeline_paused reason=vault_not_configured") })
    }

    @Test("目印が無ければ遷移せずに待つ（幻の Vault に書かない）")
    func missingMarkerIsAGuard() async throws {
        let (w, pk) = try await Self.world(marker: false)
        #expect(try await Self.ensure(w, pk) == false)
        #expect(try w.part(pk).status == .transcribed)
        #expect(w.lines("pipeline_paused").contains { $0.hasSuffix("pipeline_paused reason=vault_unavailable") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: w.vaultPath).isEmpty)
    }

    @Test("遷移の後に Vault が消えたら OBSIDIAN_NOT_FOUND")
    func vaultLostAfterTransitionFails() async throws {
        let (w, pk) = try await Self.world()
        let marker = w.vaultURL.appendingPathComponent(".obsidian", isDirectory: true)
        let assertion = RecordingSleepAssertion(onBegin: { try? FileManager.default.removeItem(at: marker) })
        #expect(try await Self.ensure(w, pk, ctx: try await w.context(assertion: assertion)) == false)
        let row = try w.part(pk)
        #expect(row.status == .failed)
        #expect(row.errorCode == .obsidianNotFound)
        #expect(
            row.errorMessage == w.vaultPath + " に .obsidian/ がありません（Vault が未マウントか、別の場所を指しています）")
        #expect(
            w.lines("raw_note_failed").contains {
                $0.hasSuffix("raw_note_failed recording_key=\(pk) error_code=OBSIDIAN_NOT_FOUND reason=vault")
            })
    }

    // MARK: - 出力先

    @Test("DB の出力パスがあればそこへ書く")
    func existingOutputPathIsKept() async throws {
        let (w, pk) = try await Self.world()
        try w.store.updateSession(Self.key, [.rawOutputPath(Self.raw2Rel)])
        #expect(try await Self.ensure(w, pk))
        #expect(try w.noteText(Self.raw2Rel) == Self.expectedR1)
        #expect(!Self.exists(w, Self.rawRel))
        #expect(try w.session(Self.key).rawOutputPath == Self.raw2Rel)
    }

    @Test("X-11 DB に無い鍵を持つノートは上書きしない")
    func foreignNoteIsNotOverwritten() async throws {
        let (w, pk) = try await Self.world()
        try Self.write(w, Self.rawRel, Self.foreignNote())
        #expect(try await Self.ensure(w, pk))
        #expect(try w.noteText(Self.rawRel) == Self.foreignNote())
        #expect(try w.noteText(Self.raw2Rel) == Self.expectedR1)
        #expect(try w.session(Self.key).rawOutputPath == Self.raw2Rel)
    }

    @Test("自分の鍵だけのノートは上書きする（rename の後に落ちた場合）")
    func ownNoteIsOverwritten() async throws {
        let (w, pk) = try await Self.world()
        let own =
            "---\ntype: \"voice-raw\"\nvoicedock_session_key: \"DJIMIC3:20260829\"\nvoicedock_recording_keys:\n"
            + "  - \"" + Self.partkeyA + "\"\n---\n\n# 古い中身\n"
        try Self.write(w, Self.rawRel, own)
        #expect(try await Self.ensure(w, pk))
        #expect(try w.noteText(Self.rawRel) == Self.expectedR1)
        #expect(!Self.exists(w, Self.raw2Rel))
    }

    @Test("99 を超えたら OBSIDIAN_RAW_WRITE_FAILED")
    func tooManyNamesFails() async throws {
        let (w, pk) = try await Self.world()
        try Self.write(w, Self.rawRel, Self.foreignNote())
        for n in 2...99 {
            try Self.write(w, Self.rawFolder + "/2026-08-29 raw (" + String(n) + ").md", Self.foreignNote())
        }
        #expect(try await Self.ensure(w, pk) == false)
        let row = try w.part(pk)
        #expect(row.status == .failed)
        #expect(row.errorCode == .obsidianRawWriteFailed)
        #expect(row.errorMessage == "同名ファイルが多すぎます: 2026-08-29 raw.md")
        #expect(
            w.lines("raw_note_failed").contains {
                $0.hasSuffix("raw_note_failed recording_key=\(pk) error_code=OBSIDIAN_RAW_WRITE_FAILED reason=write")
            })
    }

    @Test("書けなければ OBSIDIAN_RAW_WRITE_FAILED（tmp を残さない）")
    func writeFailureIsRawWriteFailed() async throws {
        let (w, pk) = try await Self.world()
        let folder = w.vaultURL.appendingPathComponent(Self.rawFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: folder.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: folder.path(percentEncoded: false))
        }
        #expect(try await Self.ensure(w, pk) == false)
        let row = try w.part(pk)
        #expect(row.status == .failed)
        #expect(row.errorCode == .obsidianRawWriteFailed)
        #expect(row.errorMessage?.hasPrefix("AtomicFileError: ") == true)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        #expect(!names.contains { $0.hasSuffix(".tmp") })
    }

    @Test("SM-15 FAILED にするのはトリガの Part だけ")
    func onlyTheTriggerFails() async throws {
        let (w, pk) = try await Self.world()
        let b = try w.addPart(PipelineFixtures.partB, status: .transcribed)
        let folder = w.vaultURL.appendingPathComponent(Self.rawFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: folder.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: folder.path(percentEncoded: false))
        }
        #expect(try await Self.ensure(w, pk) == false)
        #expect(try w.part(pk).status == .failed)
        #expect(try w.part(b).status == .transcribed)
    }

    // MARK: - 再オープン・inbox・RAW_SAVED 以降

    @Test("RAW_SAVED で確定済みの Session を再オープンする", arguments: [SessionStatus.saved, .sourceDeletePending])
    func reopensAFinishedSession(status: SessionStatus) async throws {
        let (w, pk) = try await Self.world()
        try w.forceSession(Self.key, status: status)
        #expect(try await Self.ensure(w, pk))
        #expect(try w.session(Self.key).status == .merging)
        #expect(
            w.lines("session_reopened").contains {
                $0.hasSuffix("session_reopened session_key=DJIMIC3:20260829 regenerated_count=1")
            })
    }

    @Test("CE audio.inboxRetain raw_saved なら RAW_SAVED の直後に inbox を消す")
    func ceAudioInboxRetainRawSavedReleases() async throws {
        // raw_saved: RAW_SAVED の後に inbox が無い
        let (w, pk) = try await Self.world(configure: { $0.audio.inboxRetain = "raw_saved" }, inbox: true)
        let inbox = w.layout.inboxFile(deviceID: "DJIMIC3", relpath: PipelineFixtures.partA.relpath)
        #expect(PipelineFixtures.exists(inbox))
        #expect(try await Self.ensure(w, pk))
        #expect(try w.part(pk).status == .rawSaved)
        #expect(!PipelineFixtures.exists(inbox))
        // normalized: Raw の工程では inbox に触らない
        let (w2, pk2) = try await Self.world(configure: { $0.audio.inboxRetain = "normalized" }, inbox: true)
        let inbox2 = w2.layout.inboxFile(deviceID: "DJIMIC3", relpath: PipelineFixtures.partA.relpath)
        #expect(try await Self.ensure(w2, pk2))
        #expect(try w2.part(pk2).status == .rawSaved)
        #expect(PipelineFixtures.exists(inbox2))
    }

    @Test("RAW_SAVED 以降は真を返すだけ", arguments: [PartStatus.rawSaved, .sourceDeleting, .completed])
    func rawSavedOrBeyondIsTrue(status: PartStatus) async throws {
        let (w, pk) = try await Self.world(status: status)
        #expect(try await Self.ensure(w, pk))
        #expect(try w.part(pk).status == status)
        #expect(try FileManager.default.contentsOfDirectory(atPath: w.vaultPath) == [".obsidian"])
        #expect(w.lines("pipeline_paused").isEmpty)
    }
}
