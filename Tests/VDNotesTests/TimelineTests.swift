// Timeline の組み立て・文の分割・保存形式の符号化と読み戻し（PLAN §8.6。T-27 §5.3）。
import Foundation
import Testing
import VDCore

@testable import VDNotes

@Suite("Timeline")
struct TimelineTests {
    func partial(summary: String, keyPoints: [String]) -> AnalysisView {
        AnalysisView(
            title: nil, summary: summary, keyPoints: keyPoints, decisions: nil, ideas: nil, tags: nil, tasks: nil)
    }

    func transcript(segments: [AbsoluteSegment] = [], blocks: [TimeBlock] = []) throws -> SessionTranscript {
        SessionTranscript(dayDate: try NotesFixtures.day, segments: segments, blocks: blocks, excludedPartkeys: [])
    }

    func data(_ text: String) -> Data {
        Data(text.utf8)
    }

    func decode(_ text: String, _ fingerprint: String = "FP") throws -> [TimelineBlock] {
        Timeline.decode(data(text), fingerprint: fingerprint, zone: try NotesFixtures.jst)
    }

    /// 07:12:04–07:42:04 の 1 ブロック
    func sampleBlocks() throws -> [TimelineBlock] {
        [
            TimelineBlock(
                start: try NotesFixtures.at(7, 12, 4), end: try NotesFixtures.at(7, 42, 4),
                lines: ["午前に作業した。", "午後に会議。"])
        ]
    }

    /// 正しい要素（08:00–09:00、lines ["ok"]）の JSON
    static let goodEntry =
        #"{"start_at": "2026-08-29T08:00:00+09:00", "end_at": "2026-08-29T09:00:00+09:00", "lines": ["ok"]}"#

    func document(blocks: String, schema: String = "2", fingerprint: String = "FP") -> String {
        #"{"schema": \#(schema), "transcript_sha256": "\#(fingerprint)", "blocks": \#(blocks)}"#
    }

    @Test("Map の結果があればチャンクごと")
    func buildPrefersPartials() throws {
        let chunks = [
            (start: try NotesFixtures.at(7, 0, 0), end: try NotesFixtures.at(8, 0, 0)),
            (start: try NotesFixtures.at(17, 0, 0), end: try NotesFixtures.at(18, 0, 0)),
        ]
        let blocks = Timeline.build(
            partials: [partial(summary: "朝", keyPoints: ["朝の点"]), partial(summary: "夕", keyPoints: ["夕の点"])],
            chunks: chunks, transcript: try transcript(), summary: "全体。")
        #expect(
            blocks == [
                TimelineBlock(start: try NotesFixtures.at(7, 0, 0), end: try NotesFixtures.at(8, 0, 0), lines: ["朝の点"]),
                TimelineBlock(
                    start: try NotesFixtures.at(17, 0, 0), end: try NotesFixtures.at(18, 0, 0), lines: ["夕の点"]),
            ])
    }

    @Test("key_points が無ければ summary の文")
    func partialFallsBackToSummary() throws {
        let chunk = (start: try NotesFixtures.at(7, 0, 0), end: try NotesFixtures.at(8, 0, 0))
        let blocks = Timeline.build(
            partials: [partial(summary: "A。B。", keyPoints: [])], chunks: [chunk], transcript: try transcript(),
            summary: nil)
        #expect(blocks.map(\.lines) == [["A。", "B。"]])
    }

    @Test("点の無い組は捨てる")
    func emptyPointsDropped() throws {
        let chunks = [
            (start: try NotesFixtures.at(7, 0, 0), end: try NotesFixtures.at(8, 0, 0)),
            (start: try NotesFixtures.at(9, 0, 0), end: try NotesFixtures.at(10, 0, 0)),
        ]
        let blocks = Timeline.build(
            partials: [partial(summary: "", keyPoints: []), partial(summary: "通常。", keyPoints: [])], chunks: chunks,
            transcript: try transcript(), summary: nil)
        #expect(
            blocks == [
                TimelineBlock(start: try NotesFixtures.at(9, 0, 0), end: try NotesFixtures.at(10, 0, 0), lines: ["通常。"])
            ])
    }

    @Test("短い方で打ち切る")
    func zipTruncates() throws {
        let chunks = [
            (start: try NotesFixtures.at(7, 0, 0), end: try NotesFixtures.at(8, 0, 0)),
            (start: try NotesFixtures.at(9, 0, 0), end: try NotesFixtures.at(10, 0, 0)),
        ]
        let partials = ["a。", "b。", "c。"].map { partial(summary: $0, keyPoints: []) }
        let blocks = Timeline.build(partials: partials, chunks: chunks, transcript: try transcript(), summary: nil)
        #expect(blocks.map(\.lines) == [["a。"], ["b。"]])
    }

    @Test("単一パスは Block ごとに全文を繰り返す")
    func singlePassRepeatsSentences() throws {
        let blocks = [
            TimeBlock(start: try NotesFixtures.at(7, 0, 0), end: try NotesFixtures.at(8, 0, 0)),
            TimeBlock(start: try NotesFixtures.at(10, 0, 0), end: try NotesFixtures.at(11, 0, 0)),
        ]
        let built = Timeline.build(
            partials: [], chunks: [], transcript: try transcript(blocks: blocks), summary: "A。B。 C")
        #expect(
            built == [
                TimelineBlock(
                    start: try NotesFixtures.at(7, 0, 0), end: try NotesFixtures.at(8, 0, 0), lines: ["A。", "B。", "C"]),
                TimelineBlock(
                    start: try NotesFixtures.at(10, 0, 0), end: try NotesFixtures.at(11, 0, 0),
                    lines: ["A。", "B。", "C"]),
            ])
    }

    @Test("Block が無ければ segment の範囲")
    func fallbackBlockFromSegments() throws {
        let segment = AbsoluteSegment(
            at: try NotesFixtures.at(7, 12, 0), endAt: try NotesFixtures.at(7, 12, 5), text: "一")
        let built = Timeline.build(
            partials: [], chunks: [], transcript: try transcript(segments: [segment]), summary: "A。")
        #expect(
            built == [
                TimelineBlock(start: try NotesFixtures.at(7, 12, 0), end: try NotesFixtures.at(7, 12, 5), lines: ["A。"])
            ])
    }

    @Test("summary が空なら空")
    func emptySummaryIsEmpty() throws {
        let blocks = [TimeBlock(start: try NotesFixtures.at(7, 0, 0), end: try NotesFixtures.at(8, 0, 0))]
        #expect(Timeline.build(partials: [], chunks: [], transcript: try transcript(blocks: blocks), summary: "") == [])
        #expect(
            Timeline.build(partials: [], chunks: [], transcript: try transcript(blocks: blocks), summary: nil) == [])
    }

    @Test("文の分割")
    func sentencesSplit() {
        #expect(Timeline.sentences("一文目。二文目。\n三文目 。 \n\n四") == ["一文目。", "二文目。", "三文目 。", "四"])
        #expect(Timeline.sentences("A。B。 C") == ["A。", "B。", "C"])
        #expect(Timeline.sentences("") == [])
    }

    @Test("符号化は voicedock と同じ形")
    func encodeMatchesVoicedock() throws {
        let expected =
            "{\n  \"schema\": 2,\n  \"transcript_sha256\": \"<fp>\",\n  \"blocks\": [\n    {\n"
            + "      \"start_at\": \"2026-08-29T07:12:04+09:00\",\n      \"end_at\": \"2026-08-29T07:42:04+09:00\",\n"
            + "      \"lines\": [\n        \"午前に作業した。\",\n        \"午後に会議。\"\n      ]\n    }\n  ]\n}\n"
        let actual = Timeline.encode(try sampleBlocks(), fingerprint: "<fp>", zone: try NotesFixtures.jst)
        #expect(Array(actual) == Array(expected.utf8))
    }

    @Test("符号化して読み戻せる")
    func roundTrips() throws {
        let zone = try NotesFixtures.jst
        let blocks = try sampleBlocks()
        #expect(
            Timeline.decode(Timeline.encode(blocks, fingerprint: "FP", zone: zone), fingerprint: "FP", zone: zone)
                == blocks)
    }

    @Test("別の指紋は無視する")
    func otherFingerprintIgnored() throws {
        let zone = try NotesFixtures.jst
        let encoded = Timeline.encode(try sampleBlocks(), fingerprint: "FP", zone: zone)
        #expect(Timeline.decode(encoded, fingerprint: "OTHER", zone: zone) == [])
    }

    @Test("指紋の無い形式は無視する")
    func schemaOneIgnored() throws {
        #expect(try decode("[\(Self.goodEntry)]") == [])
        #expect(try decode(document(blocks: "[\(Self.goodEntry)]", schema: "1")) == [])
        #expect(try decode(document(blocks: "[\(Self.goodEntry)]", schema: "true")) == [])
        #expect(try decode(#"{"schema": 2, "blocks": [\#(Self.goodEntry)]}"#) == [])
    }

    @Test("壊れた JSON は空")
    func brokenIsEmpty() throws {
        #expect(try decode("") == [])
        #expect(try decode("not json") == [])
        #expect(try decode("{") == [])
        #expect(try decode("[]") == [])
        #expect(Timeline.decode(Data([0xFF, 0xFE]), fingerprint: "FP", zone: try NotesFixtures.jst) == [])
    }

    @Test("壊れた要素だけ飛ばす")
    func badEntriesSkipped() throws {
        let blocks =
            #"[1, {"start_at": "x", "end_at": "2026-08-29T07:42:04+09:00", "lines": []}, "#
            + #"{"start_at": "2026-08-29T07:12:04+09:00", "end_at": "2026-08-29T07:42:04+09:00", "lines": "x"}, "#
            + Self.goodEntry + "]"
        #expect(
            try decode(document(blocks: blocks)) == [
                TimelineBlock(start: try NotesFixtures.at(8, 0, 0), end: try NotesFixtures.at(9, 0, 0), lines: ["ok"])
            ])
    }

    @Test("行の要素は str() で文字列化")
    func linesStringified() throws {
        let entry =
            #"[{"start_at": "2026-08-29T08:00:00+09:00", "end_at": "2026-08-29T09:00:00+09:00", "lines": [1, true, null, "a"]}]"#
        #expect(try decode(document(blocks: entry)).map(\.lines) == [["1", "True", "None", "a"]])
    }

    @Test("schema は 2.0 も受ける")
    func schemaFloatAccepted() throws {
        #expect(try decode(document(blocks: "[\(Self.goodEntry)]", schema: "2.0")).count == 1)
    }

    @Test("行の先頭の U+FEFF を落とさない（PyJSON.decode）")
    func leadingBOMInLineKept() throws {
        let entry =
            #"[{"start_at": "2026-08-29T08:00:00+09:00", "end_at": "2026-08-29T09:00:00+09:00", "lines": ["﻿a"]}]"#
        let lines = try #require(try decode(document(blocks: entry)).first?.lines)
        #expect(lines.map { Array($0.unicodeScalars) } == [Array("\u{FEFF}a".unicodeScalars)])
    }
}
