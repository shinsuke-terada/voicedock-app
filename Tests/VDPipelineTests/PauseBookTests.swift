// ガードの状態とログのテスト（T-18 §6.6。PLAN §5.4・付録 A.4）。
import Foundation
import TestSupport
import Testing
import VDCore
import VDTranscribe

@testable import VDPipeline

@Suite("PauseBook")
struct PauseBookTests {
    static func book() -> (PauseBook, CapturingLogSink) {
        let sink = CapturingLogSink()
        let log = AppLog(
            sink: sink, level: .debug, unsafeContent: false, zone: PipelineFixtures.zone,
            clock: FixedClock(epochMillis: 1_788_040_812_000))
        return (PauseBook(log: log), sink)
    }

    @Test("続く間は 1 回だけ出す")
    func pausedOnceWhileContinuing() {
        let (book, sink) = Self.book()
        book.trip(.whisperMissing)
        book.trip(.whisperMissing)
        book.finishTick()
        book.trip(.whisperMissing)
        book.finishTick()
        #expect(sink.lines.filter { $0.hasSuffix("WARNING pipeline_paused reason=whisper_missing") }.count == 1)
        #expect(sink.lines.count == 1)
        #expect(book.paused == [.whisperMissing])
    }

    @Test("当たらなくなった tick の終わりで出る")
    func resumedWhenNotTripped() {
        let (book, sink) = Self.book()
        book.trip(.whisperMissing)
        book.finishTick()
        book.finishTick()
        #expect(sink.lines.filter { $0.hasSuffix("INFO  pipeline_resumed reason=whisper_missing") }.count == 1)
        #expect(book.paused == [])
    }

    @Test("空き容量は disk_space_low を代わりに出す")
    func diskSpaceUsesItsOwnEvent() {
        let (book, sink) = Self.book()
        book.trip(.diskSpaceLow, recordingKey: "k", detail: "空き 1 バイトが…")
        #expect(sink.lines.contains { $0.hasSuffix("WARNING disk_space_low recording_key=k reason=\"空き 1 バイトが…\"") })
        #expect(!sink.lines.contains { $0.contains("pipeline_paused") })
    }

    @Test("paused は宣言順")
    func pausedIsInDeclarationOrder() {
        let (book, _) = Self.book()
        book.trip(.license)
        book.trip(.diskSpaceLow)
        #expect(book.paused == [.diskSpaceLow, .license])
    }

    @Test("理由の語が付録 A.4 と一致")
    func reasonWordsMatchPlan() {
        #expect(
            PauseReason.allCases.map(\.rawValue) == [
                "disk_space_low", "whisper_missing", "model_missing", "vad_model_missing", "vault_not_configured",
                "vault_unavailable", "llm_not_selected", "llm_model_missing", "llm_insufficient_memory",
                "llama_server_missing", "license",
            ])
    }

    @Test("前提の欠けの語は停止理由の語")
    func prerequisiteWordsAreReasons() {
        #expect(!TranscribePrerequisite.allCases.isEmpty)
        for m in TranscribePrerequisite.allCases {
            #expect(PauseReason(rawValue: m.rawValue) != nil)
        }
    }
}
