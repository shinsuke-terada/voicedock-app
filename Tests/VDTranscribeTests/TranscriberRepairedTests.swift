// 手前処理が直した生 JSON を無音にしないこと（PLAN §8.4 手順 7・付録 D の X-41。F-82・issue #119 のレビュー）。
// 無音（NO_SPEECH_DETECTED の SKIPPED）は根拠 B で元の録音を消しうるので、読めない文字しか無い transcript を無音と判定しない。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDProcess

@testable import VDTranscribe

@Suite("Transcriber（F-82 直した生 JSON は無音にしない）", .serialized)
struct TranscriberRepairedTests {
    typealias Fixture = TranscriberTests.Fixture

    /// 1 区間の生 JSON（text の中身はバイト列のまま。nil なら区間 0 件）を、終了 0 の whisper が書いたことにして文字起こしする。
    static func run(_ f: Fixture, textBytes: [UInt8]?) async throws -> TranscribeOutcome {
        try FakeWhisper.write(to: f.script)
        var data = Data(#"{"result": {"language": "ja"}, "transcription": ["#.utf8)
        if let textBytes {
            data.append(contentsOf: Array(#"{"offsets": {"from": 0, "to": 1500}, "text": ""#.utf8))
            data.append(contentsOf: textBytes)
            data.append(contentsOf: Array(#""}"#.utf8))
        }
        data.append(contentsOf: Array("]}".utf8))
        let runner = RawWritingRunner(json: f.whisperJSON, data: data)
        return await TranscriberStoppedTests.transcriber(f, runner: runner).transcribe(f.request())
    }

    /// run が呼ばれたら whisper.json にバイト列を書き、終了 0 を返す。
    actor RawWritingRunner: ProcessRunning {
        let json: URL
        let data: Data

        init(json: URL, data: Data) {
            self.json = json
            self.data = data
        }

        func run(_ spec: ProcessSpec, timeout: Duration) async -> ProcessResult {
            try? data.write(to: json)
            return ProcessResult(termination: .exited(0), stdoutTail: Data(), stderrTail: Data())
        }

        func spawn(_ spec: ProcessSpec) async throws(SpawnError) -> RunningProcess {
            throw SpawnError.spawnFailed(errno: ENOSYS)
        }
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    @Test(
        "F-82 直した生 JSON で読める文字が minChars に届かなければ NO_SPEECH_DETECTED にも文字起こし済みにもせず WHISPER_FAILED（transcript を書かない）",
        arguments: [
            // 制御文字だけの区間（Python 互換の strip で空になる）
            [UInt8]([0x1C, 0x1F, 0x0A]),
            // 割れた多バイト文字だけの区間（U+FFFD）
            [0xE3, 0x81],
            // strip では消えない生の制御文字だけの区間
            [0x01],
        ])
    func repairedTooShortIsFailure(_ textBytes: [UInt8]) async throws {
        let f = try Fixture()
        let outcome = try await Self.run(f, textBytes: textBytes)
        #expect(outcome == .failure(StageFailure(.whisperFailed, "生 JSON に壊れた文字があり、無音と判定できません: 0 文字（min_chars=1）")))
        #expect(!Self.exists(f.transcript))
        #expect(!Self.exists(f.whisperJSON))
    }

    @Test("F-82 直した生 JSON でも読める文字が minChars 以上なら文字起こし済み（割れた文字は U+FFFD のまま）")
    func repairedWithReadableTextIsTranscribed() async throws {
        let f = try Fixture()
        let outcome = try await Self.run(f, textBytes: [0xE3, 0x81, 0xE3, 0x81, 0x84])
        guard case .transcribed(let t, _) = outcome else {
            Issue.record("文字起こし済みになっていない: \(outcome)")
            return
        }
        #expect(t.text == "\u{FFFD}い")
        #expect(Self.exists(f.transcript))
    }

    @Test("F-82 TEST-28 直すものの無い、区間が 0 件の生 JSON は従来どおり無音（NO_SPEECH_DETECTED）")
    func unrepairedEmptyIsNoSpeech() async throws {
        let f = try Fixture()
        let outcome = try await Self.run(f, textBytes: nil)
        guard case .noSpeech(let t, let message) = outcome else {
            Issue.record("無音になっていない: \(outcome)")
            return
        }
        #expect(t.text.isEmpty)
        #expect(message == "0 文字（min_chars=1）")
    }
}
