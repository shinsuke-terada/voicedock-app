// 手前処理が直した生 JSON の Part を無音の SKIPPED（根拠 B で元の録音を消しうる）にしないこと
// （PLAN §8.4 手順 7・付録 D の X-41。F-82・issue #119 のレビュー）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDProcess
import VDStore

@testable import VDPipeline

@Suite("PartStepsTranscribe（F-82 直した生 JSON は無音にしない）", .serialized)
struct PartStepsTranscribeRepairedTests {
    /// run が呼ばれたら whisper.json（-of の値 + ".json"）にバイト列を書き、終了 0 を返す。
    actor RawWritingRunner: ProcessRunning {
        let data: Data

        init(data: Data) { self.data = data }

        func run(_ spec: ProcessSpec, timeout: Duration) async -> ProcessResult {
            if let index = spec.arguments.firstIndex(of: "-of"), index + 1 < spec.arguments.count {
                try? data.write(to: URL(fileURLWithPath: spec.arguments[index + 1] + ".json"))
            }
            return ProcessResult(termination: .exited(0), stdoutTail: Data(), stderrTail: Data())
        }

        func spawn(_ spec: ProcessSpec) async throws(SpawnError) -> RunningProcess {
            throw SpawnError.spawnFailed(errno: ENOSYS)
        }
    }

    /// 1 区間の生 JSON（text はバイト列のまま。nil なら区間 0 件）。
    static func document(textBytes: [UInt8]?) -> Data {
        var data = Data(#"{"result": {"language": "ja"}, "transcription": ["#.utf8)
        if let textBytes {
            data.append(contentsOf: Array(#"{"offsets": {"from": 0, "to": 1500}, "text": ""#.utf8))
            data.append(contentsOf: textBytes)
            data.append(contentsOf: Array(#""}"#.utf8))
        }
        data.append(contentsOf: Array("]}".utf8))
        return data
    }

    static func transcribe(_ w: PipelineWorld, _ pk: String, textBytes: [UInt8]?) async throws -> Bool {
        let ctx = try await PartStepsTranscribeStoppedTests.context(
            w, runner: RawWritingRunner(data: Self.document(textBytes: textBytes)))
        return await PartSteps(ctx: ctx).ensureTranscribed(try w.part(pk))
    }

    @Test("F-82 制御文字だけの区間（strip で空になる）の生 JSON は SKIPPED（無音）にせず FAILED（WHISPER_FAILED）で、元の録音の削除の対象にしない")
    func controlOnlyIsNotSkipped() async throws {
        let (w, pk) = try await PartStepsTranscribeTests.prepared()

        #expect(try await Self.transcribe(w, pk, textBytes: [0x1C, 0x1F, 0x0A]) == false)

        let row = try w.part(pk)
        #expect(row.status == .failed)
        #expect(row.errorCode == .whisperFailed)
        #expect(row.errorMessage == "生 JSON に壊れた文字があり、無音と判定できません: 0 文字（min_chars=1）")
        #expect(row.transcriptPath == nil)
        #expect(w.lines("part_skipped").isEmpty)
        #expect(!PartStates.deletable.contains(row.status))
    }

    @Test("F-82 TEST-28 区間が 0 件の（直すものの無い）生 JSON は従来どおり SKIPPED（NO_SPEECH_DETECTED）")
    func unrepairedEmptyIsSkipped() async throws {
        let (w, pk) = try await PartStepsTranscribeTests.prepared()

        #expect(try await Self.transcribe(w, pk, textBytes: nil) == false)

        let row = try w.part(pk)
        #expect(row.status == .skipped)
        #expect(row.errorCode == .noSpeechDetected)
        #expect(w.lines("part_skipped").contains { $0.hasSuffix("reason=no_speech") })
    }
}
