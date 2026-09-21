// Part の文字起こしの呼び手の手順のテスト（T-18 §6.8。PLAN §8.4）。本物の ProcessRunner と FakeWhisper。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDStore

@testable import VDPipeline

@Suite("PartStepsTranscribe", .serialized)
struct PartStepsTranscribeTests {
    /// installWhisper()、Part を NORMALIZED にし、staging/<slug>/audio16k.wav に 16 バイトを置き normalized_path を書く。
    static func prepared(
        utterances: [FakeWhisperUtterance] = FakeWhisper.defaultUtterances, exitCode: Int32 = 0,
        configure: (inout AppConfig) -> Void = { _ in }
    ) async throws -> (PipelineWorld, String) {
        let w = try await PipelineWorld.make(configure: configure)
        try w.installWhisper(utterances: utterances, exitCode: exitCode)
        let pk = try w.insertPart()
        try w.movePart(pk, [.normalizing, .normalized])
        let audio = w.layout.normalizedAudio(slug: KeySlug.of(pk))
        try FileManager.default.createDirectory(
            at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 16).write(to: audio)
        try w.store.updateRecording(pk, [.normalizedPath(w.layout.relativePath(of: audio))])
        return (w, pk)
    }

    static func transcribe(_ w: PipelineWorld, _ pk: String, ctx: TickContext? = nil) async throws -> Bool {
        let context: TickContext
        if let ctx {
            context = ctx
        } else {
            context = try await w.context()
        }
        return await PartSteps(ctx: context).ensureTranscribed(try w.part(pk))
    }

    static func audio(_ w: PipelineWorld, _ pk: String) -> URL { w.layout.normalizedAudio(slug: KeySlug.of(pk)) }

    /// inbox に原本を置く（Builders の行の inbox_path の位置）。
    static func putInbox(_ w: PipelineWorld) throws {
        let inbox = w.layout.inboxFile(deviceID: "DJIMIC3", relpath: PipelineFixtures.relpath)
        try FileManager.default.createDirectory(
            at: inbox.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 10).write(to: inbox)
    }

    @Test("文字起こしして 16 kHz を消す")
    func transcribesAndRemovesNormalized() async throws {
        let (w, pk) = try await Self.prepared()
        #expect(try await Self.transcribe(w, pk))
        let row = try w.part(pk)
        #expect(row.status == .transcribed)
        #expect(row.transcriptPath == "transcripts/parts/" + KeySlug.of(pk) + ".json")
        #expect(row.errorCode == nil)
        #expect(!PipelineFixtures.exists(Self.audio(w, pk)))
        let expected = "INFO  transcription_completed recording_key=\(PipelineFixtures.partkey) elapsed_s=0.0 chars=22"
        #expect(w.lines("transcription_completed").contains { $0.contains(expected) })
    }

    @Test("CE cleanup.deleteNormalizedAfterTranscribe false なら 16 kHz を残す")
    func ceDeleteNormalizedAfterTranscribe() async throws {
        let (w, pk) = try await Self.prepared { $0.cleanup.deleteNormalizedAfterTranscribe = false }
        #expect(try await Self.transcribe(w, pk))
        #expect(PipelineFixtures.exists(Self.audio(w, pk)))
    }

    @Test("無音は transcript_path を先に書いて SKIPPED")
    func noSpeechRecordsTranscriptPathFirst() async throws {
        let (w, pk) = try await Self.prepared(utterances: [])
        #expect(try await Self.transcribe(w, pk) == false)
        let row = try w.part(pk)
        #expect(row.status == .skipped)
        #expect(row.errorCode == .noSpeechDetected)
        #expect(row.transcriptPath == "transcripts/parts/" + KeySlug.of(pk) + ".json")
        #expect(w.lines("part_skipped").contains { $0.hasSuffix("reason=no_speech") })
    }

    @Test("whisper の失敗は FAILED")
    func whisperFailureIsFailed() async throws {
        let (w, pk) = try await Self.prepared(exitCode: 3)
        #expect(try await Self.transcribe(w, pk) == false)
        let row = try w.part(pk)
        #expect(row.status == .failed)
        #expect(row.errorCode == .whisperFailed)
        let expected =
            "ERROR transcription_failed recording_key=\(PipelineFixtures.partkey) error_code=WHISPER_FAILED"
        #expect(w.lines("transcription_failed").contains { $0.hasSuffix(expected) })
    }

    @Test("whisper-cli が無ければ遷移せずに待つ")
    func missingWhisperIsAGuard() async throws {
        let (w, pk) = try await Self.prepared()
        try FileManager.default.removeItem(at: w.paths.whisperCLI)
        let before = try w.partEvents(pk).count
        #expect(try await Self.transcribe(w, pk) == false)
        #expect(try w.part(pk).status == .normalized)
        #expect(try w.partEvents(pk).count == before)
        #expect(w.lines("pipeline_paused").contains { $0.hasSuffix("WARNING pipeline_paused reason=whisper_missing") })
    }

    @Test("モデルと VAD モデルの欠けも待つ")
    func missingModelsAreGuards() async throws {
        let (w, pk) = try await Self.prepared()
        for kind in [ModelKind.whisper, .vad] {
            for entry in TestCatalogs.minimal.entries(kind: kind) {
                try FileManager.default.removeItem(at: ModelFiles.url(kind: kind, entry: entry, layout: w.layout))
            }
        }
        let ctx = try await w.context()
        #expect(try await Self.transcribe(w, pk, ctx: ctx) == false)
        #expect(ctx.pauses.paused == [.modelMissing, .vadModelMissing])
        #expect(try w.part(pk).status == .normalized)
    }

    @Test("16 kHz が無く inbox が在れば NORMALIZING へ戻す")
    func missingInputRenormalizes() async throws {
        let (w, pk) = try await Self.prepared()
        try FileManager.default.removeItem(at: Self.audio(w, pk))
        try Self.putInbox(w)
        let linesBefore = w.sink.lines.count
        #expect(try await Self.transcribe(w, pk) == false)
        let row = try w.part(pk)
        #expect(row.status == .normalizing)
        #expect(row.needsRecopy == false)
        #expect(w.sink.lines.count == linesBefore)
    }

    @Test(
        "どちらも無ければ NORMALIZED_MISSING",
        arguments: [PartStatus.normalized, .transcribing])
    func missingInputAndInboxIsNormalizedMissing(_ start: PartStatus) async throws {
        let (w, pk) = try await Self.prepared()
        if start == .transcribing { try w.movePart(pk, [.transcribing]) }
        try FileManager.default.removeItem(at: Self.audio(w, pk))
        #expect(try await Self.transcribe(w, pk) == false)
        let row = try w.part(pk)
        #expect(row.status == .failed)
        #expect(row.errorCode == .normalizedMissing)
        #expect(row.needsRecopy)
        let events = try w.partEvents(pk).suffix(2).map { ($0.fromStatus ?? "", $0.toStatus) }
        #expect(events.map(\.0) == [start.rawValue, "NORMALIZING"])
        #expect(events.map(\.1) == ["NORMALIZING", "FAILED"])
        #expect(w.lines("normalize_failed").contains { $0.hasSuffix("error_code=NORMALIZED_MISSING reason=input") })
        let slug = KeySlug.of(pk)
        #expect(
            row.errorMessage
                == "16 kHz 音声も inbox の原本もありません（staging/\(slug)/audio16k.wav）。デバイスから採り直す必要があります")
    }

    @Test("0 バイトの 16 kHz は無いのと同じ")
    func emptyInputCountsAsMissing() async throws {
        let (w, pk) = try await Self.prepared()
        try Data().write(to: Self.audio(w, pk))
        #expect(try await Self.transcribe(w, pk) == false)
        let status = try w.part(pk).status
        #expect(status == .failed || status == .normalizing)
        #expect(FakeWhisper.recordedArgv(w.paths.whisperCLI) == [])
    }

    @Test("TRANSCRIBING から入っても遷移を記録しない")
    func transcribingEntryRecordsNoPhantom() async throws {
        let (w, pk) = try await Self.prepared()
        try w.movePart(pk, [.transcribing])
        #expect(try await Self.transcribe(w, pk))
        #expect(try w.part(pk).status == .transcribed)
        let entries = try w.partEvents(pk).filter { $0.fromStatus == "NORMALIZED" && $0.toStatus == "TRANSCRIBING" }
        #expect(entries.count == 1)
    }
}
