// チャンク分割が voicedock split_chunks と同じ境界になること（PLAN §8.5「Map-Reduce」、T-20）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDLLM

/// 時刻の準備（T-20 §5）。
enum ChunkFixtures {
    static let zone = ZonedTime(timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    static let base = zone.parseISO("2026-08-29T07:12:04+09:00")!

    static func seg(_ text: String, _ s: Int, _ dur: Int = 5) -> AbsoluteSegment {
        AbsoluteSegment(at: base.adding(seconds: s), endAt: base.adding(seconds: s + dur), text: text)
    }

    /// 2026-08-29 の "HH:MM:SS" を zone.iso の形にする。
    static func iso(_ time: String) -> String {
        "2026-08-29T\(time)+09:00"
    }
}

/// §5.1 の表の 1 行。
struct ChunkCase: Sendable, CustomTestStringConvertible {
    struct Seg: Sendable {
        let text: String
        let s: Int
        let dur: Int

        static func seg(_ text: String, _ s: Int, _ dur: Int = 5) -> Seg { Seg(text: text, s: s, dur: dur) }
    }

    struct Expected: Sendable, Equatable {
        let texts: [String]
        let start: String
        let end: String

        static func chunk(_ texts: [String], _ start: String, _ end: String) -> Expected {
            Expected(texts: texts, start: ChunkFixtures.iso(start), end: ChunkFixtures.iso(end))
        }
    }

    let id: String
    let maxChars: Int
    let maxSeconds: Int
    let overlap: Int
    let segs: [Seg]
    let expected: [Expected]

    var testDescription: String { id }
}

@Suite("Chunker")
struct ChunkerTests {
    static let cases: [ChunkCase] = [
        ChunkCase(
            id: "V", maxChars: 10, maxSeconds: 3600, overlap: 4,
            segs: [
                .seg("aaa", 0), .seg("bbb", 10), .seg("ccc", 20), .seg("dd", 30), .seg("eeeee", 40), .seg("ff", 5000),
            ],
            expected: [
                .chunk(["aaa", "bbb", "ccc"], "07:12:04", "07:12:29"),
                .chunk(["ccc", "dd", "eeeee"], "07:12:24", "07:12:49"),
                .chunk(["ff"], "08:35:24", "08:35:29"),
            ]),
        ChunkCase(
            id: "A", maxChars: 10, maxSeconds: 3600, overlap: 4,
            segs: [.seg("aa", 0), .seg("bb", 10), .seg("ccccccccc", 20)],
            expected: [
                .chunk(["aa", "bb"], "07:12:04", "07:12:19"),
                .chunk(["bb", "ccccccccc"], "07:12:14", "07:12:29"),
            ]),
        ChunkCase(
            id: "B", maxChars: 20_000, maxSeconds: 3600, overlap: 500,
            segs: [.seg("a", 0), .seg("b", 100), .seg("c", 4000), .seg("d", 4100)],
            expected: [
                .chunk(["a", "b"], "07:12:04", "07:13:49"),
                .chunk(["c", "d"], "08:18:44", "08:20:29"),
            ]),
        ChunkCase(
            id: "C", maxChars: 8, maxSeconds: 3600, overlap: 0,
            segs: [.seg("aaaa", 0), .seg("bbbb", 10), .seg("cccc", 20)],
            expected: [
                .chunk(["aaaa", "bbbb"], "07:12:04", "07:12:19"),
                .chunk(["cccc"], "07:12:24", "07:12:29"),
            ]),
        ChunkCase(
            id: "D", maxChars: 8, maxSeconds: 3600, overlap: 3,
            segs: [.seg("aaaa", 0), .seg("bb", 10), .seg("cccccc", 20)],
            expected: [
                .chunk(["aaaa", "bb"], "07:12:04", "07:12:19"),
                .chunk(["bb", "cccccc"], "07:12:14", "07:12:29"),
            ]),
        ChunkCase(
            id: "E", maxChars: 20_000, maxSeconds: 3600, overlap: 500,
            segs: [.seg("あいう", 0), .seg("えお", 10)],
            expected: [.chunk(["あいう", "えお"], "07:12:04", "07:12:19")]),
        ChunkCase(
            id: "F1", maxChars: 10, maxSeconds: 3600, overlap: 0,
            segs: [.seg("aaaaa", 0), .seg("bbbbb", 3595)],
            expected: [.chunk(["aaaaa", "bbbbb"], "07:12:04", "08:12:04")]),
        ChunkCase(
            id: "F2", maxChars: 10, maxSeconds: 3600, overlap: 0,
            segs: [.seg("aaaaa", 0), .seg("bbbbb", 3595, 6)],
            expected: [
                .chunk(["aaaaa"], "07:12:04", "07:12:09"),
                .chunk(["bbbbb"], "08:11:59", "08:12:05"),
            ]),
        ChunkCase(
            id: "G", maxChars: 10, maxSeconds: 3600, overlap: 4,
            segs: [.seg(String(repeating: "x", count: 15), 0), .seg("y", 10)],
            expected: [
                .chunk([String(repeating: "x", count: 15)], "07:12:04", "07:12:09"),
                .chunk(["y"], "07:12:14", "07:12:19"),
            ]),
        ChunkCase(
            id: "H", maxChars: 3, maxSeconds: 3600, overlap: 1,
            segs: [.seg("\u{304C}", 0), .seg("\u{1F44D}\u{1F3FD}", 10), .seg("e\u{0301}", 20)],
            expected: [
                .chunk(["\u{304C}", "\u{1F44D}\u{1F3FD}"], "07:12:04", "07:12:19"),
                .chunk(["\u{1F44D}\u{1F3FD}", "e\u{0301}"], "07:12:14", "07:12:29"),
            ]),
        ChunkCase(
            id: "I", maxChars: 100, maxSeconds: 3600, overlap: 0,
            segs: [.seg("aa", 0, 100), .seg("bb", 10)],
            expected: [.chunk(["aa", "bb"], "07:12:04", "07:13:44")]),
        ChunkCase(
            id: "J", maxChars: 4, maxSeconds: 3600, overlap: 1,
            segs: [.seg("aa", 0), .seg("bb", 10), .seg("bb", 10)],
            expected: [.chunk(["aa", "bb"], "07:12:04", "07:12:19")]),
        ChunkCase(
            id: "K", maxChars: 10, maxSeconds: 3600, overlap: 4,
            segs: [.seg("aaaa", 0), .seg("bbbb", 10), .seg("cccccccc", 4000)],
            expected: [
                .chunk(["aaaa", "bbbb"], "07:12:04", "07:12:19"),
                .chunk(["cccccccc"], "08:18:44", "08:18:49"),
            ]),
    ]

    /// 30 本の長さの違う segment（10 秒おき、長さ 5 秒）。
    static var thirtySegments: [AbsoluteSegment] {
        (0..<30).map { i in ChunkFixtures.seg(String(repeating: "あ", count: (i * 7) % 40 + 1) + "\(i)", i * 10) }
    }

    static func chunkThirty() -> [Chunk] {
        Chunker.chunk(thirtySegments, maxChars: 200, maxSeconds: 3600, overlapChars: 50)
    }

    @Test("チャンクの境界が voicedock と一致", arguments: cases)
    func chunkCases(case c: ChunkCase) {
        let segs = c.segs.map { ChunkFixtures.seg($0.text, $0.s, $0.dur) }
        let chunks = Chunker.chunk(segs, maxChars: c.maxChars, maxSeconds: c.maxSeconds, overlapChars: c.overlap)
        let actual = chunks.map { chunk in
            ChunkCase.Expected(
                texts: chunk.segments.map(\.text), start: ChunkFixtures.zone.iso(chunk.startAt),
                end: ChunkFixtures.zone.iso(chunk.endAt))
        }
        // text はスカラー列で比べる（H の結合文字を正準等価で見逃さないため）。
        #expect(
            actual.map { $0.texts.map { Array($0.unicodeScalars) } }
                == c.expected.map { $0.texts.map { Array($0.unicodeScalars) } })
        #expect(actual.map(\.start) == c.expected.map(\.start))
        #expect(actual.map(\.end) == c.expected.map(\.end))
        #expect(chunks.map(\.text) == c.expected.map { $0.texts.joined(separator: "\n") })
    }

    @Test("空の入力は 0 チャンク")
    func emptyInputHasNoChunks() {
        #expect(Chunker.chunk([], maxChars: 10, maxSeconds: 3600, overlapChars: 4) == [])
    }

    @Test("すべての segment がどこかに現れる")
    func everySegmentAppears() {
        let chunks = Self.chunkThirty()
        #expect(chunks.count > 1)
        for seg in Self.thirtySegments {
            #expect(chunks.contains { $0.segments.contains(seg) }, "\(seg.text) がどのチャンクにも無い")
        }
    }

    @Test("チャンクは時刻順")
    func chunksAreInTimeOrder() {
        let starts = Self.chunkThirty().map(\.startAt)
        #expect(starts.count > 1)
        #expect(zip(starts, starts.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("本文に時刻を入れない")
    func textCarriesNoTimestamps() {
        let chunks = Self.chunkThirty()
        #expect(!chunks.isEmpty)
        for chunk in chunks {
            #expect(chunk.text == chunk.segments.map(\.text).joined(separator: "\n"))
        }
    }

    @Test("golden llm_chunks", arguments: try Golden.cases("llm_chunks"))
    func goldenChunks(item: GoldenCase) throws {
        let config = try GoldenConfig.make(item)
        let zone = ZonedTime(timeZone: TimeZone(identifier: try item.string("timeZone"))!)
        let base = zone.parseISO(try item.string("base"))!
        let segments: [AbsoluteSegment] = try item.array("segments").map { value in
            guard case .object(let fields) = value, case .integer(let atMs)? = fields["atMs"],
                case .integer(let endMs)? = fields["endMs"], case .string(let text)? = fields["text"]
            else {
                throw GoldenError.typeMismatch(
                    group: item.group, name: item.name, key: "segments", expected: "{atMs, endMs, text}")
            }
            return AbsoluteSegment(
                at: base.adding(milliseconds: atMs), endAt: base.adding(milliseconds: endMs), text: text)
        }
        let chunks = Chunker.chunk(
            segments, maxChars: config.llm.maxCharsPerRequest, maxSeconds: config.llm.maxSecondsPerRequest,
            overlapChars: config.llm.chunkOverlapChars)
        let actual = GoldenJSON.array(
            chunks.map { chunk in
                .object([
                    "texts": .array(chunk.segments.map { .string($0.text) }),
                    "startMs": .integer(chunk.startAt - base),
                    "endMs": .integer(chunk.endAt - base),
                    "text": .string(chunk.text),
                ])
            })
        GoldenAssert.matchesJSON(actual, group: "llm_chunks", name: item.name)
    }

    @Test("golden llm_chunks のケースが在る")
    func goldenChunksHasCases() throws {
        #expect(!(try Golden.cases("llm_chunks")).isEmpty)
    }
}
