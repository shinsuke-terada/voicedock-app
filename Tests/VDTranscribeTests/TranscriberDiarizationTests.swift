// Transcriber の話者分離（T-48 §5。PLAN §8.4.1）。偽 whisper-cli と偽 argmax-cli を本物の ProcessRunner で起動する。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDProcess

@testable import VDTranscribe

@Suite("Transcriber（話者分離）", .serialized, .timeLimit(.minutes(1)))
struct TranscriberDiarizationTests {
    typealias Fixture = TranscriberTests.Fixture

    /// FakeWhisper の既定の 2 区間（0〜3.2 秒・5.5〜9.0 秒）を 2 人に分ける RTTM。
    static let twoSpeakers = [
        "SPEAKER audio16k 1 0.000 3.200 <NA> <NA> A <NA> <NA>",
        "SPEAKER audio16k 1 5.500 3.500 <NA> <NA> B <NA> <NA>",
    ]

    /// FakeWhisper の既定の text（TranscriberTests.expectedTranscript の text）。
    static let expectedText = "おはようございます。今日の予定を確認します。"

    /// 偽 argmax-cli と SpeakerModels を置く。
    static func prepareArgmax(
        _ f: Fixture, output: FakeArgmaxOutput = .rttm(twoSpeakers), exitCode: Int32 = 0
    ) throws {
        try FileManager.default.createDirectory(at: f.paths.speakerModels, withIntermediateDirectories: true)
        try FakeArgmax.write(to: f.paths.argmaxCLI, output: output, exitCode: exitCode)
    }

    static func transcriber(
        _ f: Fixture, diarizerRunner: (any ProcessRunning)? = ProcessRunner(),
        config: TranscriptionConfig = Fixture.defaults()
    ) -> Transcriber {
        let diarizer = diarizerRunner.map {
            Diarizer(runner: $0, paths: f.paths, layout: f.layout, maxTimeoutSeconds: config.maxTimeoutSeconds)
        }
        return Transcriber(
            runner: ProcessRunner(), paths: f.paths, layout: f.layout, config: config, catalog: f.catalog,
            clock: FixedClock(epochMillis: 1_788_000_000_000), diarizer: diarizer)
    }

    static func transcribed(_ outcome: TranscribeOutcome) -> (PartTranscript, TranscribeMetrics)? {
        if case .transcribed(let t, let m) = outcome { return (t, m) }
        return nil
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    @Test("diarizer が nil なら今と同じ transcript を書く")
    func withoutDiarizerIsUnchanged() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script)
        try Self.prepareArgmax(f)
        let outcome = await Self.transcriber(f, diarizerRunner: nil).transcribe(f.request())
        let (_, metrics) = try #require(Self.transcribed(outcome))
        let data = try Data(contentsOf: f.transcript)
        #expect(Array(data) == Array(TranscriberTests.expectedTranscript.utf8))
        #expect(!String(decoding: data, as: UTF8.self).contains("\"speaker\""))
        #expect(metrics.diarization == nil)
        #expect(FakeArgmax.recordedArgv(f.paths.argmaxCLI).isEmpty)
    }

    @Test("成功すると区間に speaker を書く")
    func diarizedTranscriptHasSpeakers() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script)
        try Self.prepareArgmax(f)
        let outcome = await Self.transcriber(f).transcribe(f.request())
        let (t, metrics) = try #require(Self.transcribed(outcome))
        #expect(t.segments.map(\.speaker) == ["A", "B"])
        let written = try #require(PartTranscriptCodec.decode(Data(contentsOf: f.transcript)))
        #expect(written.segments.map(\.speaker) == ["A", "B"])
        let text = try String(contentsOf: f.transcript, encoding: .utf8)
        #expect(text.contains("\"text\": \"おはようございます。\",\n      \"speaker\": \"A\""))
        #expect(text.contains("\"text\": \"今日の予定を確認します。\",\n      \"speaker\": \"B\""))
        // FixedClock は進まないので経過は 0
        #expect(metrics.diarization == .completed(speakers: 2, elapsedSeconds: 0))
        #expect(
            !Self.exists(f.layout.stagingDirectory(slug: TranscriberTests.slug).appending(path: "diarization.rttm")))
    }

    @Test("話者分離が失敗しても文字起こしは成功する")
    func failureStillTranscribes() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script)
        try Self.prepareArgmax(f, exitCode: 1)
        let outcome = await Self.transcriber(f).transcribe(f.request())
        let (t, metrics) = try #require(Self.transcribed(outcome))
        #expect(t.segments.map(\.speaker) == [nil, nil])
        let data = try Data(contentsOf: f.transcript)
        #expect(Array(data) == Array(TranscriberTests.expectedTranscript.utf8))
        #expect(metrics.diarization == .failed(reason: "exit_1"))
        #expect(!FakeArgmax.recordedArgv(f.paths.argmaxCLI).isEmpty)
    }

    @Test("無音には起動しない")
    func noSpeechSkipsDiarization() async throws {
        let f = try Fixture()
        // " あ" は 1 文字。minChars 2 に届かないが区間は 1 つある
        try FakeWhisper.write(to: f.script, utterances: [FakeWhisperUtterance(0, 1, " あ")])
        try Self.prepareArgmax(f)
        var config = Fixture.defaults()
        config.minChars = 2
        let outcome = await Self.transcriber(f, config: config).transcribe(f.request())
        guard case .noSpeech = outcome else {
            Issue.record("noSpeech ではない: \(outcome)")
            return
        }
        #expect(FakeArgmax.recordedArgv(f.paths.argmaxCLI).isEmpty)
    }

    @Test("話者分離が止められたら transcript を書かずに stopped")
    func stoppedDoesNotWrite() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script)
        try Self.prepareArgmax(f)
        // 話者分離の runner だけを閉じる（whisper は別の runner で動く）。閉じた後の run は ECANCELED で拒まれる
        let closed = ProcessRunner()
        await closed.terminateAll(grace: .seconds(5))
        let outcome = await Self.transcriber(f, diarizerRunner: closed).transcribe(f.request())
        #expect(outcome == .stopped)
        #expect(!Self.exists(f.transcript))
        #expect(!Self.exists(f.whisperJSON))
        #expect(!FakeWhisper.recordedArgv(f.script).isEmpty)
        #expect(FakeArgmax.recordedArgv(f.paths.argmaxCLI).isEmpty)
    }

    @Test("読める transcript が在れば起動しない")
    func idempotentSkipsDiarization() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script)
        try Self.prepareArgmax(f)
        try Data(TranscriberTests.expectedTranscript.utf8).write(to: f.transcript)
        let outcome = await Self.transcriber(f).transcribe(f.request())
        let (_, metrics) = try #require(Self.transcribed(outcome))
        #expect(metrics.diarization == nil)
        #expect(FakeArgmax.recordedArgv(f.paths.argmaxCLI).isEmpty)
        #expect(FakeWhisper.recordedArgv(f.script).isEmpty)
    }

    @Test("話者分離しても text は変わらない")
    func textIsUnchanged() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script)
        try Self.prepareArgmax(f)
        let outcome = await Self.transcriber(f).transcribe(f.request())
        let (t, _) = try #require(Self.transcribed(outcome))
        #expect(t.text == Self.expectedText)
        #expect(t.segments.map(\.text) == ["おはようございます。", "今日の予定を確認します。"])
        #expect(t.segments.map(\.start) == [0.0, 5.5])
        #expect(t.segments.map(\.end) == [3.2, 9.0])
        let written = try #require(PartTranscriptCodec.decode(Data(contentsOf: f.transcript)))
        #expect(written.text == Self.expectedText)
    }
}
