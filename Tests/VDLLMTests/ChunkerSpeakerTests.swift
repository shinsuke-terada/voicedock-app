// チャンク本文の話者の前置き（PLAN §8.5 の話者分離の行。F-89・X-45。T-50 §5）。期待は手で書く（TEST-01）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDLLM

@Suite("Chunker の話者の前置き")
struct ChunkerSpeakerTests {
    /// base から s 秒に置く 5 秒の区間。
    func seg(_ text: String, _ s: Int, _ speaker: String?) -> AbsoluteSegment {
        AbsoluteSegment(
            at: ChunkFixtures.base.adding(seconds: s), endAt: ChunkFixtures.base.adding(seconds: s + 5), text: text,
            speaker: speaker)
    }

    @Test("話者つきの区間は 話者A: を前に付ける")
    func prefixesSpeaker() {
        let chunks = Chunker.chunk(
            [seg("x", 0, "A"), seg("y", 10, "B")], maxChars: 20_000, maxSeconds: 3600, overlapChars: 500)
        #expect(chunks.map(\.text) == ["話者A: x\n話者B: y"])
    }

    @Test("話者なしのチャンクは F-89 の前と同じ", arguments: try Golden.cases("llm_chunks"))
    func withoutSpeakerUnchanged(item: GoldenCase) throws {
        let config = try GoldenConfig.make(item)
        let zone = ZonedTime(timeZone: try #require(TimeZone(identifier: try item.string("timeZone"))))
        let base = try #require(zone.parseISO(try item.string("base")))
        let segments: [AbsoluteSegment] = try item.array("segments").map { value in
            let fields = try #require(value.objectValue)
            let atMs = try #require(fields["atMs"]?.intValue)
            let endMs = try #require(fields["endMs"]?.intValue)
            return AbsoluteSegment(
                at: base.adding(milliseconds: Int64(atMs)), endAt: base.adding(milliseconds: Int64(endMs)),
                text: try #require(fields["text"]?.stringValue), speaker: nil)
        }
        let chunks = Chunker.chunk(
            segments, maxChars: config.llm.maxCharsPerRequest, maxSeconds: config.llm.maxSecondsPerRequest,
            overlapChars: config.llm.chunkOverlapChars)
        let expected = try #require(try Golden.expectedJSON("llm_chunks", item.name).arrayValue)
        let expectedTexts = try expected.map { try #require($0.objectValue?["text"]?.stringValue) }
        // バイト単位で比べる（UTF-8 のバイト列）。
        #expect(chunks.map { Array($0.text.utf8) } == expectedTexts.map { Array($0.utf8) })
    }

    @Test("切り方は話者の前置きを含めた行の文字数で決まる（F-90）")
    func countsSpeakerPrefix() {
        // 行は "話者A: aa"（7 スカラー）・"話者B: bb"（7）・"話者A: c"（6）。maxChars 14 なら 2 行で 14、3 行目で 20 > 14 で切れる。
        // text だけを数えると 2 + 2 + 1 = 5 で 1 チャンクになってしまう（F-89 の最初の実装。LLM に送る量を少なく見積もった）
        let chunks = Chunker.chunk(
            [seg("aa", 0, "A"), seg("bb", 10, "B"), seg("c", 20, "A")], maxChars: 14, maxSeconds: 3600,
            overlapChars: 0)
        #expect(chunks.map { $0.segments.map(\.text) } == [["aa", "bb"], ["c"]])
        #expect(chunks.map(\.text) == ["話者A: aa\n話者B: bb", "話者A: c"])
        // 同じ入力を話者なしにすると行は text と同じ（5 スカラー）なので 1 チャンク（voicedock と同じ数え方）
        let plain = Chunker.chunk(
            [seg("aa", 0, nil), seg("bb", 10, nil), seg("c", 20, nil)], maxChars: 14, maxSeconds: 3600,
            overlapChars: 0)
        #expect(plain.map { $0.segments.map(\.text) } == [["aa", "bb", "c"]])
    }

    @Test("重なりも話者の前置きを含めた行の文字数で数える（F-90）")
    func overlapCountsSpeakerPrefix() {
        // 行は 7・7・7・6 スカラー。maxChars 21 で 3 行、4 行目で切れる。重なりの上限 7 には "話者A: cc"（7）だけが入る。
        // text だけを数えると 2 + 2 + 2 ≤ 7 で全部が入り、先頭を落として bb と cc が重なってしまう
        let chunks = Chunker.chunk(
            [seg("aa", 0, "A"), seg("bb", 10, "B"), seg("cc", 20, "A"), seg("d", 30, "B")], maxChars: 21,
            maxSeconds: 3600, overlapChars: 7)
        #expect(chunks.map { $0.segments.map(\.text) } == [["aa", "bb", "cc"], ["cc", "d"]])
    }

    @Test("区間 0 はチャンク 0（TEST-28）")
    func empty() {
        #expect(Chunker.chunk([], maxChars: 4, maxSeconds: 3600, overlapChars: 0) == [])
    }
}
