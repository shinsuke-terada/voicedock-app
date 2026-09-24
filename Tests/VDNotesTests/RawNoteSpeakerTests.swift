// Raw ノートの話者の行（PLAN §8.6 の話者分離の段落と例。F-89・X-45。T-50 §5）。期待は PLAN の例から手で書く（TEST-01）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDNotes

@Suite("RawNote の話者の行")
struct RawNoteSpeakerTests {
    /// 10:15:02+09:00 に始まる 1 Part（終了 10:45:02）。PLAN §8.6 の例の `### 10:15:02` に合わせる。
    func partAt1015(_ segments: [AbsoluteSegment]) throws -> RawPart {
        RawPart(
            partkey: NotesFixtures.keyA, startedAt: "2026-08-29T10:15:02+09:00", endedAt: "2026-08-29T10:45:02+09:00",
            segments: segments, zone: try NotesFixtures.jst)
    }

    /// 10:15:02 からの秒数に置く 10 秒の区間。
    func seg(_ offset: Int, _ text: String, _ speaker: String?) throws -> AbsoluteSegment {
        let at = try NotesFixtures.at(10, 15, 2).adding(seconds: offset)
        return AbsoluteSegment(at: at, endAt: at.adding(seconds: 10), text: text, speaker: speaker)
    }

    @Test("PLAN §8.6 の例と同じ行になる")
    func planExample() throws {
        let part = try partAt1015([
            try seg(0, "今日の打ち合わせを始めます。", "A"),
            try seg(10, "よろしくお願いします。資料は…", "B"),
            try seg(20, "では最初の議題から。", "A"),
        ])
        #expect(
            RawNote.segmentLines(part, interval: 300) == [
                "### 10:15:02",
                "",
                "**話者A**: 今日の打ち合わせを始めます。",
                "**話者B**: よろしくお願いします。資料は…",
                "**話者A**: では最初の議題から。",
                "",
            ])
    }

    @Test("続けて同じ話者の区間は 1 行に半角空白でつなぐ")
    func sameSpeakerJoinsWithSpace() throws {
        let part = try partAt1015([try seg(0, "x", "A"), try seg(10, "y", "A"), try seg(20, "z", "B")])
        #expect(RawNote.segmentLines(part, interval: 300) == ["### 10:15:02", "", "**話者A**: x y", "**話者B**: z", ""])
    }

    @Test("話者なしの区間は text だけの行")
    func unlabeledSegmentIsPlainLine() throws {
        let part = try partAt1015([try seg(0, "x", "A"), try seg(10, "y", nil), try seg(20, "z", "A")])
        #expect(
            RawNote.segmentLines(part, interval: 300) == [
                "### 10:15:02", "", "**話者A**: x", "y", "**話者A**: z", "",
            ])
    }

    @Test("### の差し込みで行が切れる")
    func timestampBreaksTurns() throws {
        // 0 秒と 100 秒は同じ ###、310 秒は 10:15:02 + 300 秒 = 10:20:02 以降なので新しい ###（時刻は区間の時刻 10:20:12）
        let part = try partAt1015([try seg(0, "x", "A"), try seg(100, "y", "A"), try seg(310, "z", "A")])
        #expect(
            RawNote.segmentLines(part, interval: 300) == [
                "### 10:15:02", "", "**話者A**: x y", "", "### 10:20:12", "", "**話者A**: z", "",
            ])
    }

    @Test("話者の無い Part は F-89 の前と同じ", arguments: try Golden.cases("raw_note"))
    func partWithoutSpeakersIsUnchanged(item: GoldenCase) throws {
        let config = try GoldenConfig.make(item)
        let zone = ZonedTime(timeZone: try #require(TimeZone(identifier: try item.string("timeZone"))))
        var parts: [RawPart] = []
        for json in try item.array("parts") {
            let fields = try #require(json.objectValue)
            let startedAt = try #require(fields["startedAt"]?.stringValue)
            let base = try #require(zone.parseISO(startedAt))
            var segments: [AbsoluteSegment] = []
            for segment in try #require(fields["segments"]?.arrayValue) {
                let s = try #require(segment.objectValue)
                let startMs = try #require(s["startMs"]?.intValue)
                let endMs = try #require(s["endMs"]?.intValue)
                segments.append(
                    AbsoluteSegment(
                        at: base.adding(milliseconds: Int64(startMs)), endAt: base.adding(milliseconds: Int64(endMs)),
                        text: try #require(s["text"]?.stringValue), speaker: nil))
            }
            parts.append(
                RawPart(
                    partkey: try #require(fields["partkey"]?.stringValue), startedAt: startedAt,
                    endedAt: fields["endedAt"]?.stringValue, segments: segments, zone: zone))
        }
        let actual = RawNote.render(
            parts: parts, day: try #require(LocalDate(dashed: try item.string("day"))),
            sessionKey: try item.string("sessionKey"), config: config.obsidian)
        #expect(Data(actual.utf8) == (try Golden.expectedBytes("raw_note", item.name)))
    }

    @Test("話者の無い Part と在る Part が同じノートに並ぶ")
    func mixedParts() throws {
        let partA = RawPart(
            partkey: NotesFixtures.keyA, startedAt: "2026-08-29T07:12:04+09:00", endedAt: "2026-08-29T07:42:04+09:00",
            segments: [
                NotesFixtures.seg(try NotesFixtures.at(7, 12, 4), "おはようございます。"),
                NotesFixtures.seg(try NotesFixtures.at(7, 13, 4), "削除条件を整理します。"),
            ], zone: try NotesFixtures.jst)
        let at1 = try NotesFixtures.at(7, 42, 10)
        let at2 = try NotesFixtures.at(7, 42, 20)
        let at3 = try NotesFixtures.at(7, 42, 30)
        // Part 2 は話者つきに話者なしの区間を 1 つ混ぜる（分岐の条件が「全区間に話者」だと段落になって落ちる）
        let partB = RawPart(
            partkey: NotesFixtures.keyB, startedAt: "2026-08-29T07:42:10+09:00", endedAt: "2026-08-29T08:12:10+09:00",
            segments: [
                AbsoluteSegment(at: at1, endAt: at1.adding(seconds: 10), text: "続きです。", speaker: "A"),
                AbsoluteSegment(at: at2, endAt: at2.adding(seconds: 10), text: "（相づち）", speaker: nil),
                AbsoluteSegment(at: at3, endAt: at3.adding(seconds: 10), text: "はい。", speaker: "B"),
            ], zone: try NotesFixtures.jst)
        let expected = """
            ---
            type: "voice-raw"
            voicedock_session_key: "DJIMIC3:20260829"
            voicedock_recording_keys:
              - "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
              - "DJIMIC3/TX_MIC001_20260829_074201/TX01_MIC002_20260829_074210_orig.wav"
            date: "2026-08-29"
            parts: 2
            source: "DJI Mic 3"
            ---

            # 2026-08-29 の文字起こし（生データ）

            > 自動文字起こしの生データ。未編集。

            ## 07:12–07:42

            ### 07:12:04

            おはようございます。 削除条件を整理します。

            ## 07:42–08:12

            ### 07:42:10

            **話者A**: 続きです。
            （相づち）
            **話者B**: はい。

            """
        let actual = RawNote.render(
            parts: [partA, partB], day: try NotesFixtures.day, sessionKey: NotesFixtures.sessionKey,
            config: NotesFixtures.config())
        #expect(actual == expected)
    }

    @Test("話者つきでも text が全部空なら本文なし（TEST-28）")
    func emptySpeakerPart() throws {
        let at = try NotesFixtures.at(7, 12, 4)
        let part = RawPart(
            partkey: NotesFixtures.keyA, startedAt: "2026-08-29T07:12:04+09:00", endedAt: "2026-08-29T07:42:04+09:00",
            segments: [
                AbsoluteSegment(at: at, endAt: at.adding(seconds: 10), text: " \t ", speaker: "A"),
                AbsoluteSegment(at: at.adding(seconds: 10), endAt: at.adding(seconds: 20), text: "", speaker: "A"),
            ], zone: try NotesFixtures.jst)
        let expected = """
            ---
            type: "voice-raw"
            voicedock_session_key: "DJIMIC3:20260829"
            voicedock_recording_keys:
              - "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
            date: "2026-08-29"
            parts: 1
            source: "DJI Mic 3"
            ---

            # 2026-08-29 の文字起こし（生データ）

            > 自動文字起こしの生データ。未編集。

            ## 07:12–07:42

            """
        let actual = RawNote.render(
            parts: [part], day: try NotesFixtures.day, sessionKey: NotesFixtures.sessionKey,
            config: NotesFixtures.config())
        #expect(RawNote.segmentLines(part, interval: 300) == [])
        #expect(actual == expected)
        #expect(!actual.contains("###"))
    }

    @Test("interval 0 でも話者の行になる")
    func intervalZero() throws {
        let part = try partAt1015([try seg(0, "x", "A"), try seg(10, "y", "B"), try seg(400, "z", "A")])
        #expect(RawNote.segmentLines(part, interval: 0) == ["**話者A**: x", "**話者B**: y", "**話者A**: z", ""])
    }
}
