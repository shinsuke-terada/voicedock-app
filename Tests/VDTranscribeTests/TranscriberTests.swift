// Transcriber のテスト（T-17 §6.3。PLAN §8.4）。偽 whisper-cli を本物の ProcessRunner で起動する。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDProcess

@testable import VDTranscribe

@Suite("Transcriber", .serialized)
struct TranscriberTests {
    static let partkey = "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
    static let slug = KeySlug.of(partkey)
    static let startedAt = "2026-08-29T07:12:04+09:00"
    static let duration = 1800.0

    /// 期待するファイル（voicedock の json.dumps(…, ensure_ascii=False, indent=2) + "\n" の実測）。
    static let expectedTranscript = """
        {
          "partkey": "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav",
          "language": "ja",
          "duration_seconds": 1800.0,
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

    /// テスト内のカタログ（whisper 2 つ・vad 2 つ。bytes はすべて 4）。
    static let catalogJSON: String = {
        let commit = String(repeating: "0", count: 40)
        let sha = String(repeating: "a", count: 64)
        func item(_ id: String, _ file: String) -> String {
            """
            {"id": "\(id)", "displayName": "\(id)", "file": "\(file)", \
            "url": "https://huggingface.co/x/y/resolve/\(commit)/\(file)", \
            "sha256": "\(sha)", "bytes": 4, "license": "MIT"}
            """
        }
        return """
            {"schema": 1,
             "whisper": [\(item("large-v3-turbo-q5_0", "ggml-large-v3-turbo-q5_0.bin")), \
            \(item("medium-q5_0", "ggml-medium-q5_0.bin"))],
             "vad": [\(item("silero-v5.1.2", "ggml-silero-v5.1.2.bin")), \(item("silero-v4", "ggml-silero-v4.bin"))],
             "llm": []}
            """
    }()

    /// テストごとの環境（一時ディレクトリ・HomeLayout・AppPaths・カタログ・モデル・入力）。
    struct Fixture {
        let tmp: TempDirectory
        let layout: HomeLayout
        let paths: AppPaths
        let catalog: ModelCatalog
        /// HOME のパス（末尾の / 無し）。
        let home: String

        init() throws {
            tmp = try TempDirectory()
            layout = HomeLayout(root: tmp.url.appending(path: "home", directoryHint: .isDirectory))
            try layout.createDirectories()
            paths = AppPaths(
                resources: tmp.url.appending(path: "resources", directoryHint: .isDirectory),
                helpers: tmp.url.appending(path: "helpers", directoryHint: .isDirectory))
            try FileManager.default.createDirectory(at: paths.helpers, withIntermediateDirectories: true)
            guard case .success(let loaded) = ModelCatalog.load(Data(TranscriberTests.catalogJSON.utf8)),
                loaded.rejected.isEmpty
            else {
                throw FixtureError.catalog
            }
            catalog = loaded
            var root = layout.root.path(percentEncoded: false)
            if root.hasSuffix("/") { root.removeLast() }
            home = root
            for file in ["ggml-large-v3-turbo-q5_0.bin", "ggml-medium-q5_0.bin"] {
                try Data("1234".utf8).write(to: layout.modelFile(kind: "whisper", file: file))
            }
            for file in ["ggml-silero-v5.1.2.bin", "ggml-silero-v4.bin"] {
                try Data("1234".utf8).write(to: layout.modelFile(kind: "vad", file: file))
            }
            try FileManager.default.createDirectory(
                at: layout.stagingDirectory(slug: TranscriberTests.slug), withIntermediateDirectories: true)
            try Data("RIFF....WAVEfmt ".utf8).write(to: layout.normalizedAudio(slug: TranscriberTests.slug))
        }

        static func defaults() -> TranscriptionConfig { AppConfig.defaults(timeZone: "Asia/Tokyo").transcription }

        var script: URL { paths.whisperCLI }
        var transcript: URL { layout.transcript(slug: TranscriberTests.slug) }
        var whisperJSON: URL { layout.whisperJSON(slug: TranscriberTests.slug) }

        func transcriber(_ config: TranscriptionConfig = Fixture.defaults()) -> Transcriber {
            Transcriber(
                runner: ProcessRunner(), paths: paths, layout: layout, config: config, catalog: catalog,
                clock: FixedClock(epochMillis: 1_788_000_000_000))
        }

        func request(duration: Double? = TranscriberTests.duration) -> TranscribeRequest {
            TranscribeRequest(
                partkey: TranscriberTests.partkey, slug: TranscriberTests.slug,
                input: layout.normalizedAudio(slug: TranscriberTests.slug), durationSeconds: duration,
                startedAt: TranscriberTests.startedAt)
        }

        func run(_ config: TranscriptionConfig = Fixture.defaults(), duration: Double? = TranscriberTests.duration)
            async -> TranscribeOutcome
        {
            await transcriber(config).transcribe(request(duration: duration))
        }

        func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
    }

    enum FixtureError: Error { case catalog }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    static func value(after flag: String, in argv: [String]) -> String? {
        guard let index = argv.firstIndex(of: flag), index + 1 < argv.count else { return nil }
        return argv[index + 1]
    }

    static func failure(_ outcome: TranscribeOutcome) -> StageFailure? {
        if case .failure(let f) = outcome { return f }
        return nil
    }

    static func isTranscribed(_ outcome: TranscribeOutcome) -> Bool {
        if case .transcribed = outcome { return true }
        return false
    }

    // MARK: - 成功と出力

    @Test("正規化 transcript が voicedock と同じバイト列")
    func writesNormalizedTranscriptBytes() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script)
        let outcome = await f.run()
        #expect(Self.isTranscribed(outcome))
        let data = try Data(contentsOf: f.transcript)
        #expect(Array(data) == Array(Self.expectedTranscript.utf8))
    }

    @Test("argv が配列で渡る")
    func argvIsPassedAsArray() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script)
        _ = await f.run()
        let h = f.home
        let s = Self.slug
        let threads = String(min(ProcessInfo.processInfo.activeProcessorCount, 8))
        #expect(
            FakeWhisper.recordedArgv(f.script) == [
                "-m", "\(h)/models/whisper/ggml-large-v3-turbo-q5_0.bin", "-f", "\(h)/staging/\(s)/audio16k.wav",
                "-l", "ja", "-t", threads, "--vad", "--vad-model", "\(h)/models/vad/ggml-silero-v5.1.2.bin",
                "--vad-threshold", "0.5", "--vad-min-speech-duration-ms", "250", "--vad-min-silence-duration-ms",
                "1000", "--vad-speech-pad-ms", "200", "-oj", "-of", "\(h)/staging/\(s)/whisper", "-np",
            ])
    }

    @Test("成功後に whisper.json が残らない")
    func rawJSONIsRemovedAfterSuccess() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script)
        let outcome = await f.run()
        #expect(Self.isTranscribed(outcome))
        #expect(!Self.exists(f.whisperJSON))
        let names = try FileManager.default.contentsOfDirectory(
            atPath: f.layout.transcriptsParts.path(percentEncoded: false))
        #expect(names == ["\(Self.slug).json"])
    }

    // MARK: - 冪等

    @Test("読める transcript があれば whisper を起動しない")
    func existingTranscriptIsReused() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script)
        _ = await f.run()
        try f.remove(URL(fileURLWithPath: f.script.path(percentEncoded: false) + ".argv"))
        let outcome = await f.run()
        #expect(Self.isTranscribed(outcome))
        #expect(FakeWhisper.recordedArgv(f.script).isEmpty)
    }

    @Test("壊れた transcript は作り直す")
    func brokenTranscriptIsRegenerated() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script)
        try Data("{".utf8).write(to: f.transcript)
        let outcome = await f.run()
        #expect(!FakeWhisper.recordedArgv(f.script).isEmpty)
        #expect(Self.isTranscribed(outcome))
    }

    @Test("minChars 未満の transcript は作り直す")
    func shortTranscriptIsRegenerated() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script)
        let empty = PartTranscript(
            partkey: Self.partkey, language: "ja", durationSeconds: Self.duration, startedAt: Self.startedAt, text: "",
            segments: [])
        try PartTranscriptCodec.encode(empty).write(to: f.transcript)
        _ = await f.run()
        #expect(!FakeWhisper.recordedArgv(f.script).isEmpty)
    }

    // MARK: - 失敗の写し方

    @Test("終了コード ≠ 0 は WHISPER_FAILED")
    func nonzeroExitIsWhisperFailed() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script, exitCode: 3, stderr: "boom")
        let outcome = await f.run()
        #expect(outcome == .failure(StageFailure(.whisperFailed, "終了コード 3: boom")))
        #expect(!Self.exists(f.whisperJSON))
    }

    @Test("stderr の末尾 1000 字を残す")
    func stderrTailIsKept() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script, exitCode: 1, stderr: String(repeating: "x", count: 4000) + "REAL_CAUSE")
        let failure = try #require(Self.failure(await f.run()))
        #expect(failure.code == .whisperFailed)
        #expect(failure.message.hasSuffix("REAL_CAUSE"))
        let prefix = "終了コード 1: "
        #expect(failure.message.hasPrefix(prefix))
        #expect(failure.message.unicodeScalars.count - prefix.unicodeScalars.count == 1000)
    }

    @Test("シグナルで終わると WHISPER_FAILED")
    func signalIsWhisperFailed() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script, selfSignal: 9)
        let failure = try #require(Self.failure(await f.run()))
        #expect(failure.code == .whisperFailed)
        #expect(failure.message.hasPrefix("シグナル 9: "))
    }

    @Test("起動できなければ WHISPER_EXEC_MISSING")
    func spawnFailureIsExecMissing() async throws {
        let f = try Fixture()
        try Data("not a script".utf8).write(to: f.script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: f.script.path(percentEncoded: false))
        let outcome = await f.run()
        #expect(outcome == .failure(StageFailure(.whisperExecMissing, "spawn: errno 8")))
    }

    @Test("終了 0 でも JSON が無ければ WHISPER_FAILED")
    func exitZeroWithoutJSONIsFailed() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script, output: .none)
        let outcome = await f.run()
        #expect(outcome == .failure(StageFailure(.whisperFailed, "生 JSON を読めません: staging/\(Self.slug)/whisper.json")))
    }

    @Test("壊れた JSON は WHISPER_FAILED")
    func brokenJSONIsFailed() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script, output: .broken)
        let outcome = await f.run()
        #expect(outcome == .failure(StageFailure(.whisperFailed, "生 JSON を読めません: staging/\(Self.slug)/whisper.json")))
        #expect(!Self.exists(f.whisperJSON))
    }

    @Test("タイムアウトで孫まで消える")
    func timeoutKillsProcessGroup() async throws {
        let f = try Fixture()
        let marker = f.tmp.url.appending(path: "marker")
        try FakeWhisper.write(to: f.script, sleepSeconds: 3, grandchildMarker: marker)
        var config = Fixture.defaults()
        config.minTimeoutSeconds = 1
        config.maxTimeoutSeconds = 1
        let clock = ContinuousClock()
        let began = clock.now
        let outcome = await f.run(config)
        let took = clock.now - began
        #expect(outcome == .failure(StageFailure(.whisperTimeout, "1 秒を超えました")))
        #expect(took < .seconds(10))
        try await Task.sleep(for: .seconds(4))
        #expect(!Self.exists(marker))
    }

    @Test("タイムアウトで whisper.json を消す")
    func timeoutRemovesPartialOutput() async throws {
        let f = try Fixture()
        let marker = f.tmp.url.appending(path: "marker")
        try FakeWhisper.write(to: f.script, sleepSeconds: 3, grandchildMarker: marker)
        try Data("{\"partial\": ".utf8).write(to: f.whisperJSON)
        var config = Fixture.defaults()
        config.minTimeoutSeconds = 1
        config.maxTimeoutSeconds = 1
        let outcome = await f.run(config)
        #expect(Self.failure(outcome)?.code == .whisperTimeout)
        #expect(!Self.exists(f.whisperJSON))
    }

    // MARK: - 無音

    @Test("発話なしは失敗ではない")
    func noSpeechIsNotFailure() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script, utterances: [])
        let outcome = await f.run()
        guard case .noSpeech(let t, let message) = outcome else {
            Issue.record("noSpeech ではない: \(outcome)")
            return
        }
        #expect(message == "0 文字（min_chars=1）")
        #expect(t.text == "")
    }

    @Test("ASR-09 無音でも transcript を先に書く")
    func noSpeechStillWritesTranscript() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script, utterances: [])
        _ = await f.run()
        let data = try Data(contentsOf: f.transcript)
        let t = try #require(PartTranscriptCodec.decode(data))
        #expect(t.text == "")
    }

    @Test("CE transcription.minChars を守る")
    func minCharsIsRespected() async throws {
        let one = try Fixture()
        try FakeWhisper.write(to: one.script, utterances: [FakeWhisperUtterance(0, 1, " あ")])
        #expect(Self.isTranscribed(await one.run()))

        let two = try Fixture()
        try FakeWhisper.write(to: two.script, utterances: [FakeWhisperUtterance(0, 1, " あ")])
        var config = Fixture.defaults()
        config.minChars = 2
        let outcome = await two.run(config)
        guard case .noSpeech(_, let message) = outcome else {
            Issue.record("noSpeech ではない: \(outcome)")
            return
        }
        #expect(message == "1 文字（min_chars=2）")

        // 結合文字: "か\u{3099}" は 2 スカラー・1 書記素。スカラー数で数えるので minChars 2 を満たす。
        let combining = try Fixture()
        try FakeWhisper.write(to: combining.script, utterances: [FakeWhisperUtterance(0, 1, " か\u{3099}")])
        #expect(Self.isTranscribed(await combining.run(config)))
    }

    // MARK: - モデルの選択（CE）

    @Test("CE transcription.whisperModelID を変えると -m のパスが変わる")
    func ceWhisperModelID() async throws {
        let base = try Fixture()
        try FakeWhisper.write(to: base.script)
        _ = await base.run()
        #expect(
            Self.value(after: "-m", in: FakeWhisper.recordedArgv(base.script))
                == "\(base.home)/models/whisper/ggml-large-v3-turbo-q5_0.bin")

        let f = try Fixture()
        try FakeWhisper.write(to: f.script)
        var config = Fixture.defaults()
        config.whisperModelID = "medium-q5_0"
        _ = await f.run(config)
        #expect(
            Self.value(after: "-m", in: FakeWhisper.recordedArgv(f.script))
                == "\(f.home)/models/whisper/ggml-medium-q5_0.bin")
    }

    @Test("CE transcription.vad.modelID を変えると --vad-model のパスが変わる")
    func ceVADModelID() async throws {
        let base = try Fixture()
        try FakeWhisper.write(to: base.script)
        _ = await base.run()
        #expect(
            Self.value(after: "--vad-model", in: FakeWhisper.recordedArgv(base.script))
                == "\(base.home)/models/vad/ggml-silero-v5.1.2.bin")

        let f = try Fixture()
        try FakeWhisper.write(to: f.script)
        var config = Fixture.defaults()
        config.vad.modelID = "silero-v4"
        _ = await f.run(config)
        #expect(
            Self.value(after: "--vad-model", in: FakeWhisper.recordedArgv(f.script))
                == "\(f.home)/models/vad/ggml-silero-v4.bin")
    }

    // MARK: - 前提

    @Test("whisper-cli が無ければ前提の欠け")
    func missingCLIIsPrerequisite() async throws {
        let f = try Fixture()
        let outcome = await f.run()
        #expect(outcome == .prerequisiteMissing(.whisperMissing))
        #expect(!Self.exists(f.transcript))
        #expect(!Self.exists(f.whisperJSON))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: f.layout.transcriptsParts.path(percentEncoded: false))
                .isEmpty)
    }

    @Test("モデルが無い・大きさが違えば前提の欠け")
    func missingModelIsPrerequisite() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script)
        try Data("123".utf8).write(to: f.layout.modelFile(kind: "whisper", file: "ggml-large-v3-turbo-q5_0.bin"))
        #expect(await f.run() == .prerequisiteMissing(.modelMissing))
        #expect(FakeWhisper.recordedArgv(f.script).isEmpty)

        try f.remove(f.layout.modelFile(kind: "whisper", file: "ggml-large-v3-turbo-q5_0.bin"))
        #expect(await f.run() == .prerequisiteMissing(.modelMissing))
    }

    @Test("VAD モデルは VAD 有効のときだけ要る")
    func missingVADModelIsPrerequisiteOnlyWhenEnabled() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script)
        try f.remove(f.layout.modelFile(kind: "vad", file: "ggml-silero-v5.1.2.bin"))
        #expect(await f.run() == .prerequisiteMissing(.vadModelMissing))

        var config = Fixture.defaults()
        config.vad.enabled = false
        #expect(Self.isTranscribed(await f.run(config)))
    }

    @Test("欠けを全部返す")
    func missingPrerequisitesListsAll() throws {
        let f = try Fixture()
        try f.remove(f.layout.modelFile(kind: "whisper", file: "ggml-large-v3-turbo-q5_0.bin"))
        try f.remove(f.layout.modelFile(kind: "vad", file: "ggml-silero-v5.1.2.bin"))
        #expect(f.transcriber().missingPrerequisites() == [.whisperMissing, .modelMissing, .vadModelMissing])
    }

    // MARK: - タイムアウトの式

    @Test(
        "タイムアウトの式",
        arguments: zip(
            [nil, 10, 199.9, 200, 1800, 7200, 1_000_000] as [Double?],
            [21_600, 600, 600, 600, 5400, 21_600, 21_600]))
    func timeoutTable(duration: Double?, expected: Int) {
        #expect(Transcriber.timeoutSeconds(duration: duration, config: Fixture.defaults()) == expected)
    }

    @Test("CE transcription.timeoutFactor を 1.0 にすると上限が縮む")
    func ceTranscriptionTimeoutFactor() {
        var config = Fixture.defaults()
        #expect(Transcriber.timeoutSeconds(duration: 1800, config: config) == 5400)
        config.timeoutFactor = 1.0
        #expect(Transcriber.timeoutSeconds(duration: 1800, config: config) == 1800)
    }

    @Test("CE transcription.minTimeoutSeconds が下限になる")
    func ceTranscriptionMinTimeoutSeconds() {
        var config = Fixture.defaults()
        #expect(Transcriber.timeoutSeconds(duration: 10, config: config) == 600)
        config.minTimeoutSeconds = 60
        #expect(Transcriber.timeoutSeconds(duration: 10, config: config) == 60)
    }

    @Test("CE transcription.maxTimeoutSeconds が上限（duration 不明のときの値）")
    func ceTranscriptionMaxTimeoutSeconds() {
        var config = Fixture.defaults()
        #expect(Transcriber.timeoutSeconds(duration: nil, config: config) == 21_600)
        #expect(Transcriber.timeoutSeconds(duration: 7200, config: config) == 21_600)
        config.maxTimeoutSeconds = 900
        #expect(Transcriber.timeoutSeconds(duration: nil, config: config) == 900)
        #expect(Transcriber.timeoutSeconds(duration: 7200, config: config) == 900)
    }

    // MARK: - メトリクス

    @Test("メトリクス")
    func metricsMatchSpec() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script)
        let outcome = await f.run()
        #expect(outcome.metrics == TranscribeMetrics(elapsedSeconds: 0, chars: 22, rtf: 0.0, speechRatio: 0.004))
    }

    @Test("duration が nil か 0 なら rtf と speechRatio は nil", arguments: [nil, 0.0] as [Double?])
    func metricsDoNotDivideByZero(duration: Double?) async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script)
        let metrics = try #require(await f.run(duration: duration).metrics)
        #expect(metrics.rtf == nil)
        #expect(metrics.speechRatio == nil)
    }
}

extension TranscribeOutcome {
    /// `.transcribed` のメトリクス（それ以外は nil）。
    fileprivate var metrics: TranscribeMetrics? {
        if case .transcribed(_, let metrics) = self { return metrics }
        return nil
    }
}
