// Raw ノートの固定例（voicedock@d3d595e の実出力。移植メモ V5 §3.4。T-26 §5.4）。
import Foundation
import Testing
import VDCore

@testable import VDNotes

@Suite("RawNote")
struct RawNoteTests {
    /// 期待 A（twoPartsMatchVoicedock）。
    static let expectedA = """
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

        おはようございます。

        ### 07:17:04

        削除条件を整理します。

        ## 07:42–08:12

        ### 07:42:10

        続きです。

        """

    func render(_ parts: [RawPart], config: ObsidianConfig = NotesFixtures.config()) throws -> String {
        RawNote.render(parts: parts, day: try NotesFixtures.day, sessionKey: NotesFixtures.sessionKey, config: config)
    }

    /// 07:00:00+09:00 に始まる 1 Part（終了 07:30:00）。
    func partAt7(_ segments: [AbsoluteSegment]) throws -> RawPart {
        RawPart(
            partkey: NotesFixtures.keyA, startedAt: "2026-08-29T07:00:00+09:00", endedAt: "2026-08-29T07:30:00+09:00",
            segments: segments, zone: try NotesFixtures.jst)
    }

    /// 07:00 から 2 分刻みの 10 区間（"<m> 分"）。
    func twoMinuteSegments() throws -> [AbsoluteSegment] {
        try stride(from: 0, to: 20, by: 2).map { m in NotesFixtures.seg(try NotesFixtures.at(7, m, 0), "\(m) 分") }
    }

    func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    func headings(_ text: String) -> [String] {
        lines(text).filter { $0.hasPrefix("### ") }
    }

    func scalars(_ s: String) -> [UInt32] {
        s.unicodeScalars.map(\.value)
    }

    @Test("2 Part の Raw ノートは voicedock と同じ")
    func twoPartsMatchVoicedock() throws {
        let rendered = try render([try NotesFixtures.partB, try NotesFixtures.partA])
        #expect(scalars(rendered) == scalars(Self.expectedA))
    }

    @Test("終了時刻が無い Part")
    func partWithoutEnd() throws {
        let at = NotesFixtures.at
        let seg = NotesFixtures.seg
        let part = RawPart(
            partkey: NotesFixtures.keyA, startedAt: "2026-08-29T07:12:04+09:00", endedAt: nil,
            segments: [
                seg(try at(7, 12, 4), "  x  ", 10), seg(try at(7, 13, 0), "   ", 10), seg(try at(7, 13, 4), "---", 10),
                seg(try at(7, 18, 3), "y", 10), seg(try at(7, 18, 4), "z", 10),
            ],
            zone: try NotesFixtures.jst)
        let rendered = try render([part])
        #expect(rendered.hasSuffix("## 07:12–\n\n### 07:12:04\n\nx ---\n\n### 07:18:03\n\ny z\n"))
    }

    @Test("CE obsidian.raw.partBoundaryHeading false で Part の ## 見出しが消える")
    func cePartBoundaryHeading() throws {
        let parts = [try NotesFixtures.partA, try NotesFixtures.partB]
        let withHeading = try render(parts)
        #expect(withHeading.contains("\n## 07:12–07:42\n"))
        var config = NotesFixtures.config()
        config.raw.partBoundaryHeading = false
        let rendered = try render(parts, config: config)
        #expect(!lines(rendered).contains { $0.hasPrefix("## ") })
        #expect(headings(rendered) == ["### 07:12:04", "### 07:17:04", "### 07:42:10"])
    }

    @Test("CE obsidian.raw.timestampIntervalSeconds を変えると ### の刻みが変わる")
    func ceTimestampIntervalSeconds() throws {
        let part = try partAt7(try twoMinuteSegments())
        #expect(headings(try render([part])).count == 4)
        var config = NotesFixtures.config()
        config.raw.timestampIntervalSeconds = 600
        #expect(headings(try render([part], config: config)) == ["### 07:00:00", "### 07:10:00"])
        config.raw.timestampIntervalSeconds = 0
        #expect(headings(try render([part], config: config)).isEmpty)
    }

    @Test("CE obsidian.raw.folderTemplate が Raw ノートの置き場所になる")
    func ceRawFolderTemplate() throws {
        var config = NotesFixtures.config()
        #expect(RawNote.folder(config: config, day: try NotesFixtures.day) == "Daily/Voice/Raw/20260829")
        config.raw.folderTemplate = "Voice/{date}"
        #expect(RawNote.folder(config: config, day: try NotesFixtures.day) == "Voice/2026-08-29")
    }

    @Test("見出しを無効にした設定")
    func headingsDisabled() throws {
        var config = NotesFixtures.config()
        config.raw.timestampIntervalSeconds = 0
        config.raw.partBoundaryHeading = false
        let rendered = try render([try NotesFixtures.partA, try NotesFixtures.partB], config: config)
        #expect(
            rendered.hasSuffix(
                "> 自動文字起こしの生データ。未編集。\n\nおはようございます。 削除条件を整理します。\n\n続きです。\n"))
        #expect(!lines(rendered).contains { $0.hasPrefix("## ") })
        #expect(headings(rendered).isEmpty)
    }

    @Test("Part が 0 件でも描ける")
    func noPartsStillRenders() throws {
        let rendered = try render([])
        #expect(rendered.contains("\nvoicedock_recording_keys: []\n"))
        #expect(rendered.contains("\nparts: 0\n"))
        #expect(rendered.hasSuffix("\n\n> 自動文字起こしの生データ。未編集。\n"))
    }

    @Test("本文の無い Part でも ## は出る")
    func partWithoutTextKeepsHeading() throws {
        let b = try NotesFixtures.partB
        let silent = RawPart(
            partkey: b.partkey, startedAt: b.startedAt, endedAt: b.endedAt,
            segments: [NotesFixtures.seg(try NotesFixtures.at(7, 42, 10), "   ")], zone: b.zone)
        let rendered = try render([try NotesFixtures.partA, silent])
        #expect(rendered.hasSuffix("## 07:42–08:12\n"))
    }

    @Test("300 秒ごとの見出しは実際の区間の時刻")
    func timestampIntervalUsesActualTimes() throws {
        let rendered = try render([try partAt7(try twoMinuteSegments())])
        #expect(headings(rendered) == ["### 07:00:00", "### 07:06:00", "### 07:12:00", "### 07:18:00"])
    }

    @Test("ちょうど 300 秒で次の見出し")
    func boundaryIsInclusive() throws {
        let part = try partAt7([
            NotesFixtures.seg(try NotesFixtures.at(7, 0, 0), "a"),
            NotesFixtures.seg(try NotesFixtures.at(7, 5, 0), "b"),
        ])
        #expect(headings(try render([part])) == ["### 07:00:00", "### 07:05:00"])
    }

    @Test("ミリ秒の境界")
    func millisecondBoundary() throws {
        let base = try NotesFixtures.at(7, 0, 0)
        let first = NotesFixtures.seg(base, "a")
        let justBefore = NotesFixtures.seg(base.adding(milliseconds: 299_999), "b")
        let exactly = NotesFixtures.seg(base.adding(milliseconds: 300_000), "c")
        #expect(headings(try render([try partAt7([first, justBefore])])) == ["### 07:00:00"])
        #expect(
            headings(try render([try partAt7([first, justBefore, exactly])])) == ["### 07:00:00", "### 07:05:00"])
    }

    @Test("同じ見出しの下は半角空白でつなぐ")
    func segmentsJoinWithSingleSpace() throws {
        let rendered = try render([try NotesFixtures.partA])
        #expect(rendered.contains("### 07:12:04\n\nおはようございます。\n\n### 07:17:04\n\n削除条件を整理します。"))
    }

    @Test("空の区間は見出しを作らない")
    func emptySegmentsAreDropped() throws {
        let part = try partAt7([
            NotesFixtures.seg(try NotesFixtures.at(7, 0, 0), "   "),
            NotesFixtures.seg(try NotesFixtures.at(7, 0, 30), "本文"),
        ])
        #expect(headings(try render([part])) == ["### 07:00:30"])
    }

    @Test("本文は加工しない（strip だけ）")
    func bodyIsNotProcessed() throws {
        let part = try partAt7([NotesFixtures.seg(try NotesFixtures.at(7, 0, 0), "  えーと、あの… 「テスト」だ。  ")])
        #expect(try render([part]).contains("\nえーと、あの… 「テスト」だ。\n"))
    }

    @Test("行頭 --- の区間は退避される")
    func leadingDashesAreEscaped() throws {
        let part = try partAt7([NotesFixtures.seg(try NotesFixtures.at(7, 0, 0), "---")])
        let rendered = try render([part])
        #expect(rendered.contains("\n\\---\n"))
        let document = try #require(Frontmatter.parse(rendered))
        #expect(document[Frontmatter.keySessionKey] as? String == NotesFixtures.sessionKey)
    }

    @Test("frontmatter の項目")
    func frontmatterFields() throws {
        let rendered = try render([try NotesFixtures.partA, try NotesFixtures.partB])
        let document = try #require(Frontmatter.parse(rendered))
        #expect(document["type"] as? String == "voice-raw")
        #expect(
            Frontmatter.stringList(document, Frontmatter.keyRecordingKeys) == [NotesFixtures.keyA, NotesFixtures.keyB])
        #expect(document["date"] as? String == "2026-08-29")
        #expect(document["parts"] as? Int == 2)
        #expect(document["source"] as? String == "DJI Mic 3")
        #expect(document["voicedock_session_id"] == nil)
    }

    @Test("見出しの時刻は保存文字列のオフセット")
    func wallClockUsesStoredOffset() throws {
        let a = try NotesFixtures.partA
        let utc = RawPart(
            partkey: a.partkey, startedAt: a.startedAt, endedAt: a.endedAt, segments: a.segments,
            zone: ZonedTime(timeZone: try #require(TimeZone(identifier: "UTC"))))
        let rendered = try render([utc])
        #expect(rendered.contains("\n## 07:12–07:42\n"))
        #expect(rendered.contains("\n### 07:12:04\n"))
    }

    @Test("決定的")
    func deterministic() throws {
        let parts = [try NotesFixtures.partA, try NotesFixtures.partB]
        #expect(try render(parts) == (try render(parts)))
    }
}
