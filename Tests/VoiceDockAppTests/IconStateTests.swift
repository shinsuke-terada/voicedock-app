// IconState（メニューバーのアイコンの状態）のテスト（T-30 §5.2）。
import Testing

@testable import VoiceDockApp

@Suite("IconState")
struct IconStateTests {
    @Test("要対応は取り込み・処理より優先")
    func attentionWins() {
        let state = IconState.compute(hasAttention: true, ingesting: true, processing: true)
        #expect(state == .attention)
        #expect(state.symbolName == "exclamationmark.triangle")
    }

    @Test("取り込み中は処理中より先")
    func ingestingBeatsProcessing() {
        let state = IconState.compute(hasAttention: false, ingesting: true, processing: true)
        #expect(state == .ingesting)
        #expect(state.symbolName == "arrow.down.circle")
    }

    @Test("Worker が動いていれば処理中")
    func processingWhenWorkerBusy() {
        let state = IconState.compute(hasAttention: false, ingesting: false, processing: true)
        #expect(state == .processing)
        #expect(state.symbolName == "text.bubble")
    }

    @Test("何も無ければ待機中")
    func idleOtherwise() {
        let state = IconState.compute(hasAttention: false, ingesting: false, processing: false)
        #expect(state == .idle)
        #expect(state.symbolName == "waveform")
    }

    @Test("4 つの記号名が全部違う")
    func symbolNamesAreDistinct() {
        let names = Set(IconState.allCases.map(\.symbolName))
        #expect(names.count == 4)
        #expect(!names.contains(IconState.trashSymbolName))
        #expect(IconState.trashSymbolName == "trash")
    }
}
