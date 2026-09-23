// Raw ノートの本文を守る（F-75。PLAN §8.6〜§8.8・X-38。issue #115）: トリガが載らない Raw を保存済みにしない・書き直しで本文を消さない。
import Foundation
import GRDB
import TestSupport
import Testing
import VDContract
import VDCore
import VDNotes

@testable import VDPipeline
@testable import VDStore

@Suite("RawNoteStep（F-75）", .serialized, .timeLimit(.minutes(1)))
struct RawNoteTextProtectionTests {
    typealias Step = RawNoteStepTests
    static let key = Step.key
    static let rawRel = Step.rawRel
    static let raw2Rel = Step.raw2Rel
    /// A の transcript が読めないときの error_message（HOME からの相対パス。slug は partkey の SHA-256 の先頭 16 文字の固定値）
    static let unreadableA = "文字起こしを読めません: transcripts/parts/a5d046dce76cfedc.json"

    static func removeTranscript(_ w: PipelineWorld, _ pk: String) throws {
        try FileManager.default.removeItem(at: w.layout.transcript(slug: KeySlug.of(pk)))
    }

    static func failedLine(_ w: PipelineWorld, _ pk: String) -> Bool {
        w.lines("raw_note_failed").contains {
            $0.hasSuffix("raw_note_failed recording_key=\(pk) error_code=OBSIDIAN_RAW_WRITE_FAILED reason=write")
        }
    }

    /// テストだけの近道（Tests/ は PT-05 の対象外。本番のコードは使わない）。
    static func setStartedAt(_ w: PipelineWorld, _ pk: String, _ value: String) throws {
        try w.store.pool.write { db in
            try db.execute(sql: "UPDATE recordings SET started_at = ? WHERE partkey = ?", arguments: [value, pk])
        }
    }

    static func vaultEntries(_ w: PipelineWorld) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: w.vaultPath).sorted()
    }

    // MARK: - D1: トリガが載らない

    @Test("F-75 トリガの transcript が読めなければ FAILED（トリガだけの Session。黙って止まらない）")
    func unreadableTriggerAloneFails() async throws {
        let (w, pk) = try await Step.world()
        try Self.removeTranscript(w, pk)
        #expect(try await Step.ensure(w, pk) == false)
        let row = try w.part(pk)
        #expect(row.status == .failed)
        #expect(row.errorCode == .obsidianRawWriteFailed)
        #expect(row.errorMessage == Self.unreadableA)
        #expect(Self.failedLine(w, pk))
        let events = try w.partEvents(pk)
        #expect(events.contains { $0.fromStatus == "TRANSCRIBED" && $0.toStatus == "RAW_WRITING" })
        #expect(events.contains { $0.fromStatus == "RAW_WRITING" && $0.toStatus == "FAILED" })
        #expect(try Self.vaultEntries(w) == [".obsidian"])
    }

    @Test("F-75 トリガの transcript が読めなければ、ほかの Part が載っても RAW_SAVED にしない")
    func unreadableTriggerWithOthersFails() async throws {
        let (w, pk) = try await Step.world()
        let b = try w.addPart(PipelineFixtures.partB, status: .rawSaved)
        try Self.removeTranscript(w, pk)
        #expect(try await Step.ensure(w, pk) == false)
        let row = try w.part(pk)
        #expect(row.status == .failed)
        #expect(row.errorCode == .obsidianRawWriteFailed)
        #expect(row.errorMessage == Self.unreadableA)
        #expect(try w.part(b).status == .rawSaved)
        #expect(!Step.exists(w, Self.rawRel))
        #expect(try w.session(Self.key).rawOutputPath == nil)
    }

    @Test("F-75 started_at が読めないトリガも FAILED（開始時刻を読めません）")
    func unparsableStartedAtFails() async throws {
        let (w, pk) = try await Step.world()
        try Self.setStartedAt(w, pk, "bad")
        #expect(try await Step.ensure(w, pk) == false)
        let row = try w.part(pk)
        #expect(row.status == .failed)
        #expect(row.errorCode == .obsidianRawWriteFailed)
        #expect(row.errorMessage == "開始時刻を読めません: bad")
    }

    @Test("F-75 再試行は RAW_WRITING に戻る（読めないままなら再び FAILED、transcript が戻れば RAW_SAVED）")
    func requeueReturnsToRawWriting() async throws {
        let (w, pk) = try await Step.world()
        let transcriptURL = w.layout.transcript(slug: KeySlug.of(pk))
        let saved = try Data(contentsOf: transcriptURL)
        try Self.removeTranscript(w, pk)
        #expect(try await Step.ensure(w, pk) == false)
        let requeue = Requeue(ctx: try await w.context())
        // 読めないまま
        #expect(try requeue.resumeFailed(entity: .recording, key: pk, resetRetry: true, detail: "requeue"))
        #expect(try w.part(pk).status == .rawWriting)
        #expect(try await Step.ensure(w, pk) == false)
        #expect(try w.part(pk).status == .failed)
        #expect(w.lines("raw_note_failed").count == 2)
        // transcript が戻った
        #expect(try requeue.resumeFailed(entity: .recording, key: pk, resetRetry: true, detail: "requeue"))
        try AtomicFile.write(saved, to: transcriptURL)
        #expect(try await Step.ensure(w, pk))
        #expect(try w.part(pk).status == .rawSaved)
        #expect(try w.noteText(Self.rawRel) == Step.expectedR1)
    }

    // MARK: - D2: 書き直しで本文を消さない

    @Test(
        "F-75 書き直しで RAW_SAVED 以降の Part の本文が消えるなら書かずにトリガを FAILED",
        arguments: [PartStatus.rawSaved, .sourceDeleting, .sourceDeletePending, .completed])
    func rewriteThatLosesSavedTextFails(status: PartStatus) async throws {
        let (w, pk) = try await Step.world()
        #expect(try await Step.ensure(w, pk))
        let before = try w.session(Self.key)
        try w.forcePart(pk, status: status, sessionKey: Self.key)
        try Self.removeTranscript(w, pk)
        let b = try w.addPart(PipelineFixtures.partB, status: .transcribed)
        #expect(try await Step.ensure(w, b) == false)
        let row = try w.part(b)
        #expect(row.status == .failed)
        #expect(row.errorCode == .obsidianRawWriteFailed)
        #expect(
            row.errorMessage
                == "書き直すと Raw ノートから本文が消える Part があります（1 本）: " + Step.partkeyA + "。" + Self.unreadableA)
        #expect(Self.failedLine(w, b))
        // Raw ノートも DB の記録も元のまま
        #expect(try w.noteText(Self.rawRel) == Step.expectedR1)
        let after = try w.session(Self.key)
        #expect(after.rawOutputPath == before.rawOutputPath)
        #expect(after.rawOutputSHA256 == before.rawOutputSHA256)
        #expect(try w.part(pk).status == status)
    }

    @Test("F-75 RAW_SAVED より前の Part の鍵は書き直しで外れてもよい（原本は消えていない）")
    func unsavedPartMayDrop() async throws {
        let (w, pk) = try await Step.world()
        let b = try w.addPart(PipelineFixtures.partB, status: .transcribed, segments: nil)
        let own =
            "---\ntype: \"voice-raw\"\nvoicedock_session_key: \"DJIMIC3:20260829\"\nvoicedock_recording_keys:\n"
            + "  - \"" + pk + "\"\n  - \"" + b + "\"\n---\n\n# 古い中身\n"
        try Step.write(w, Self.rawRel, own)
        try w.store.updateSession(Self.key, [.rawOutputPath(Self.rawRel)])
        #expect(try await Step.ensure(w, pk))
        #expect(try w.part(pk).status == .rawSaved)
        #expect(try w.noteText(Self.rawRel) == Step.expectedR1)
    }

    @Test("F-75 書き込み先にノートが無ければ守る鍵を見ずに書く")
    func absentNoteIsWritten() async throws {
        let (w, pk) = try await Step.world()
        #expect(try await Step.ensure(w, pk))
        try w.forcePart(pk, status: .completed, sessionKey: Self.key)
        try Self.removeTranscript(w, pk)
        try FileManager.default.removeItem(at: w.vaultURL.appendingPathComponent(Self.rawRel))
        let b = try w.addPart(PipelineFixtures.partB, status: .transcribed)
        #expect(try await Step.ensure(w, b))
        #expect(try w.part(b).status == .rawSaved)
        let text = try w.noteText(Self.rawRel)
        #expect(text.contains("  - \"" + b + "\"\n"))
        #expect(!text.contains(pk))
        #expect(text.contains("parts: 1\n"))
    }

    @Test("F-75 読めない既存ノートは上書きせず (2) に書く（本文を消さない）")
    func unreadableNoteIsKept() async throws {
        let (w, pk) = try await Step.world()
        let url = w.vaultURL.appendingPathComponent(Self.rawRel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFile.write(Data([0xFF, 0x0A]), to: url)
        try w.store.updateSession(Self.key, [.rawOutputPath(Self.rawRel)])
        #expect(try await Step.ensure(w, pk))
        #expect(try Data(contentsOf: url) == Data([0xFF, 0x0A]))
        #expect(try w.noteText(Self.raw2Rel) == Step.expectedR1)
        #expect(try w.session(Self.key).rawOutputPath == Self.raw2Rel)
    }

    // MARK: - F4 / F5: 出力先

    @Test("F-75 Raw は同じ場所の Daily ノート（type: voice-daily）を置き換えない")
    func rawDoesNotReplaceDaily() async throws {
        let (w, pk) = try await Step.world()
        let daily =
            "---\ntype: \"voice-daily\"\nvoicedock_session_key: \"DJIMIC3:20260829\"\nvoicedock_recording_keys:\n"
            + "  - \"" + pk + "\"\nvoicedock_failed_parts: []\nvoicedock_skipped_parts: []\n---\n\n# 2026-08-29\n"
        try Step.write(w, Self.rawRel, daily)
        #expect(try await Step.ensure(w, pk))
        #expect(try w.noteText(Self.rawRel) == daily)
        #expect(try w.noteText(Self.raw2Rel) == Step.expectedR1)
        #expect(try w.session(Self.key).rawOutputPath == Self.raw2Rel)
    }

    @Test("F-75 DB の出力パスのフォルダが消えていれば今のフォルダに書き、DB のパスを移す")
    func missingOldFolderMovesPath() async throws {
        let (w, pk) = try await Step.world()
        try w.store.updateSession(Self.key, [.rawOutputPath("Old/Raw/2026-08-29 raw.md")])
        #expect(try await Step.ensure(w, pk))
        #expect(try w.part(pk).status == .rawSaved)
        #expect(try w.noteText(Self.rawRel) == Step.expectedR1)
        #expect(try w.session(Self.key).rawOutputPath == Self.rawRel)
        #expect(!Step.exists(w, "Old"))
    }
}
