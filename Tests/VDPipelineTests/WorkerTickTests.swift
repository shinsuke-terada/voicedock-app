// Worker の 1 tick の結合テスト（T-18 §6.10）。BWF → 本物の AVFoundation → FakeWhisper。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDStore

@testable import VDPipeline

@Suite("WorkerTick", .serialized, .timeLimit(.minutes(1)))
struct WorkerTickTests {
    /// T-17 §6.3 の期待（duration_seconds は 2.0。voicedock の json.dumps(…, ensure_ascii=False, indent=2) + "\n"）。
    static let expectedTranscript = """
        {
          "partkey": "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav",
          "language": "ja",
          "duration_seconds": 2.0,
          "started_at": "2026-08-29T07:12:04+09:00",
          "text": "おはようございます。今日の予定を確認します。",
          "segments": [
            {
              "start": 0.0,
              "end": 3.2,
              "text": "おはようございます。"
            },
            {
              "start": 5.5,
              "end": 9.0,
              "text": "今日の予定を確認します。"
            }
          ]
        }

        """

    static func argvFile(_ w: PipelineWorld) -> URL {
        URL(fileURLWithPath: w.paths.whisperCLI.path(percentEncoded: false) + ".argv")
    }

    @Test("1 tick で DISCOVERED → TRANSCRIBED")
    func tickCarriesAPartToTranscribed() async throws {
        let w = try await PipelineWorld.make()
        try w.installWhisper()
        let pk = try w.registerPart()
        await w.worker().tick()
        #expect(try w.part(pk).status == .transcribed)
        let to = try w.partEvents(pk).map(\.toStatus)
        #expect(to == ["DISCOVERED", "NORMALIZING", "NORMALIZED", "TRANSCRIBING", "TRANSCRIBED"])
        let slug = KeySlug.of(pk)
        let data = try Data(contentsOf: w.layout.transcript(slug: slug))
        #expect(Array(data) == Array(Self.expectedTranscript.utf8))
        #expect(!PipelineFixtures.exists(w.layout.inboxFile(deviceID: "DJIMIC3", relpath: PipelineFixtures.relpath)))
        #expect(!PipelineFixtures.exists(w.layout.normalizedAudio(slug: slug)))
    }

    @Test("2 回目の tick は何もしない（Raw は T-29）")
    func secondTickIsIdempotent() async throws {
        let w = try await PipelineWorld.make()
        try w.installWhisper()
        let pk = try w.registerPart()
        let worker = w.worker()
        await worker.tick()
        #expect(try w.part(pk).status == .transcribed)
        try FileManager.default.removeItem(at: Self.argvFile(w))
        let before = try w.partEvents(pk).count
        await worker.tick()
        #expect(try w.partEvents(pk).count == before)
        #expect(FakeWhisper.recordedArgv(w.paths.whisperCLI) == [])
    }

    @Test("whisper の失敗は工程内で 3 回")
    func failedWhisperIsRetriedInProcess() async throws {
        let w = try await PipelineWorld.make()
        try w.installWhisper(exitCode: 1)
        let pk = try w.registerPart()
        let sleeper = LimitedSleeper(limit: 10)
        await Worker(deps: w.deps(sleeper: sleeper), assertion: w.assertion, onStage: nil).tick()
        let row = try w.part(pk)
        #expect(row.status == .failed)
        #expect(row.errorCode == .whisperFailed)
        #expect(row.retryCount == 3)
        #expect(sleeper.recorded == [3, 10])
    }

    @Test("空の DB で tick")
    func emptyDatabaseTick() async throws {
        let w = try await PipelineWorld.make()
        await w.worker().tick()
        #expect(w.sink.lines == [])
    }
}
