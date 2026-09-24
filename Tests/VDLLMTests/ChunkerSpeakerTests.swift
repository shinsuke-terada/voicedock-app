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

    @Test("切り方は text の文字数だけで決まる")
    func countsOnlyText() {
        // maxChars 4 に text がちょうど 4 スカラー（"aa" + "bb"）。前置き "話者A: " を数えると超えるが、数えないので 1 チャンク。
        // 次の "c" で 5 > 4 になり、そこで切れる（重なり 0）。
        let chunks = Chunker.chunk(
            [seg("aa", 0, "A"), seg("bb", 10, "B"), seg("c", 20, "A")], maxChars: 4, maxSeconds: 3600,
            overlapChars: 0)
        #expect(chunks.map { $0.segments.map(\.text) } == [["aa", "bb"], ["c"]])
        #expect(chunks.map(\.text) == ["話者A: aa\n話者B: bb", "話者A: c"])
        // 同じ入力を話者なしにしても同じ位置で切れる（期待は同じ手書きの値）
        let plain = Chunker.chunk(
            [seg("aa", 0, nil), seg("bb", 10, nil), seg("c", 20, nil)], maxChars: 4, maxSeconds: 3600,
            overlapChars: 0)
        #expect(plain.map { $0.segments.map(\.text) } == [["aa", "bb"], ["c"]])
    }

    @Test("区間 0 はチャンク 0（TEST-28）")
    func empty() {
        #expect(Chunker.chunk([], maxChars: 4, maxSeconds: 3600, overlapChars: 0) == [])
    }
}
