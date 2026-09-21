// Daily ノートの本文・frontmatter の固定例（voicedock@d3d595e の実出力。移植メモ V5 §4.5。T-27 §5.1）。
import Foundation
import Testing
import VDCore

@testable import VDNotes

/// T-27 §5 の固定値（T-26 の NotesFixtures に足す）。
extension NotesFixtures {
    static let analysisFull = AnalysisView(
        title: "開発と打ち合わせの一日", summary: "VoiceDock の削除条件を整理した。午後に MVP の範囲を確定した。",
        keyPoints: ["削除の根拠をテキストの保全に置く"], decisions: ["MVP では GUI を作らない"], ideas: ["将来的に話者識別を追加する"],
        tags: ["VoiceDock", "DJI Mic", "a: b", "c \"d\"", "e\\f", "  ", "全角\u{3000}空白"],
        tasks: [("DJI Mic 3 のマウント構造を確認する", nil), ("Whisper の速度を実測する", "2026-09-05")])

    static let linksFull = LinkPlan(
        dailyNote: "[[2026-08-29]]", adjacent: ["[[2026-08-28 Voice]]", "[[2026-08-30 Voice]]"],
        tags: ["[[VoiceDock]]", "#DJI-Mic"], raw: ["[[2026-08-29 raw]]"], dropped: [])

    static var timelineFull: [TimelineBlock] {
        get throws {
            [
                TimelineBlock(start: try at(7, 12, 0), end: try at(11, 12, 0), lines: ["朝の移動中に整理した", "二点目"]),
                TimelineBlock(start: try at(13, 12, 0), end: try at(19, 12, 0), lines: ["MVP を確定した"]),
            ]
        }
    }

    static let excludedFull = [
        ExcludedPart(partkey: "DJIMIC3/F/f_orig.wav", status: .failed, errorCode: .whisperFailed, unknownCode: nil),
        ExcludedPart(
            partkey: "DJIMIC3/S/s1_orig.wav", status: .skipped, errorCode: .noSpeechDetected, unknownCode: nil),
        ExcludedPart(
            partkey: "DJIMIC3/S/s2_orig.wav", status: .skipped, errorCode: .duplicateContent, unknownCode: nil),
    ]

    static func appConfig() -> AppConfig {
        AppConfig.defaults(timeZone: "Asia/Tokyo")
    }
}

@Suite("DailyNote")
struct DailyNoteTests {
    /// 期待 B（fullNoteMatchesVoicedock）。最後の行の後に \n が 1 つ。
    static let expectedB = """
        ---
        type: "voice-daily"
        voicedock_session_key: "DJIMIC3:20260829"
        voicedock_recording_keys:
          - "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
          - "DJIMIC3/TX_MIC001_20260829_074201/TX01_MIC002_20260829_074210_orig.wav"
        voicedock_failed_parts:
          - "DJIMIC3/F/f_orig.wav"
        voicedock_skipped_parts:
          - "DJIMIC3/S/s1_orig.wav"
          - "DJIMIC3/S/s2_orig.wav"
        date: "2026-08-29"
        recorded: "09:41:20"
        parts: 2
        blocks: 2
        status: "processed"
        tags:
          - "voice"
          - "voicedock"
          - "DJI-Mic"
          - "a:-b"
          - "c-\\"d\\""
          - "e\\\\f"
          - "全角-空白"
        ---

        # 開発と打ち合わせの一日

        > ⚠ この日の録音のうち 1 本が処理できませんでした。次にデバイスを接続したときに自動で再試行されます。

        > この日の録音のうち 2 本を除外しました（重複・無音）。自動では再試行されません。

        ## Summary

        VoiceDock の削除条件を整理した。午後に MVP の範囲を確定した。

        ## Timeline

        ### 07:12–11:12

        - 朝の移動中に整理した
        - 二点目

        ### 13:12–19:12

        - MVP を確定した

        ## Key Points

        - 削除の根拠をテキストの保全に置く

        ## Tasks

        - [ ] DJI Mic 3 のマウント構造を確認する
        - [ ] Whisper の速度を実測する 📅 2026-09-05

        ## Decisions

        - MVP では GUI を作らない

        ## Ideas

        - 将来的に話者識別を追加する

        ## Sources

        - [[2026-08-29 raw]]

        ## Links

        - [[2026-08-29]]
        - [[2026-08-28 Voice]]
        - [[2026-08-30 Voice]]
        - [[VoiceDock]]

        """

    /// 期待 C（minimalNoteMatchesVoicedock）。
    static let expectedC = """
        ---
        type: "voice-daily"
        voicedock_session_key: "DJIMIC3:20260829"
        voicedock_recording_keys: []
        voicedock_failed_parts: []
        voicedock_skipped_parts:
          - "DJIMIC3/S/s3_orig.wav"
          - "DJIMIC3/S/s4_orig.wav"
          - "DJIMIC3/S/s5_orig.wav"
        date: "2026-08-29"
        recorded: "00:00:00"
        parts: 0
        blocks: 0
        status: "processed"
        tags:
          - "voice"
          - "voicedock"
        ---

        # 題

        > ⚠ この日の録音のうち 3 本を除外しました（元ファイルが見つかりません・LLM_FAILED・理由不明）。自動では再試行されません。デバイスから採り直してください。

        ## Summary

        一文目。二文目。

        """

    /// 期待 B の入力（引数で一部だけ差し替える）。
    func input(
        analysis: AnalysisView = NotesFixtures.analysisFull, recordingKeys: [String]? = nil,
        excluded: [ExcludedPart] = NotesFixtures.excludedFull, recordedSeconds: Double? = 34_880.9,
        blockCount: Int = 2, timeline: [TimelineBlock]? = nil, links: LinkPlan = NotesFixtures.linksFull
    ) throws -> DailyInput {
        DailyInput(
            analysis: analysis, day: try NotesFixtures.day, sessionKey: NotesFixtures.sessionKey,
            recordingKeys: recordingKeys ?? [NotesFixtures.keyA, NotesFixtures.keyB], excluded: excluded,
            recordedSeconds: recordedSeconds, blockCount: blockCount,
            timeline: try timeline ?? NotesFixtures.timelineFull,
            links: links, zone: try NotesFixtures.jst)
    }

    func render(_ input: DailyInput, _ config: AppConfig = NotesFixtures.appConfig()) -> String {
        DailyNote.render(input, config: config)
    }

    /// analysisFull の一部だけを差し替えたもの
    func analysis(
        title: String? = NotesFixtures.analysisFull.title, summary: String? = NotesFixtures.analysisFull.summary,
        keyPoints: [String]? = NotesFixtures.analysisFull.keyPoints,
        decisions: [String]? = NotesFixtures.analysisFull.decisions,
        ideas: [String]? = NotesFixtures.analysisFull.ideas,
        tags: [String]? = NotesFixtures.analysisFull.tags,
        tasks: [(text: String, due: String?)]? = NotesFixtures.analysisFull.tasks
    ) -> AnalysisView {
        AnalysisView(
            title: title, summary: summary, keyPoints: keyPoints, decisions: decisions, ideas: ideas, tags: tags,
            tasks: tasks)
    }

    /// 本文の行（LF で割る）
    func lines(_ text: String) -> [String] {
        ScalarText.splitLF(text)
    }

    /// `##` で始まる見出しの行を順に（`###` を除く）
    func headings(_ text: String) -> [String] {
        lines(text).filter { ScalarText.hasPrefix($0, "## ") }
    }

    @Test("全部入りの Daily ノートは voicedock と同じ")
    func fullNoteMatchesVoicedock() throws {
        #expect(Array(render(try input()).utf8) == Array(Self.expectedB.utf8))
    }

    @Test("最小形の Daily ノートは voicedock と同じ")
    func minimalNoteMatchesVoicedock() throws {
        let minimal = AnalysisView(
            title: "題", summary: "一文目。二文目。", keyPoints: [], decisions: [], ideas: [], tags: [], tasks: [])
        let excluded = [
            ExcludedPart(
                partkey: "DJIMIC3/S/s3_orig.wav", status: .skipped, errorCode: .sourceMissing, unknownCode: nil),
            ExcludedPart(partkey: "DJIMIC3/S/s4_orig.wav", status: .skipped, errorCode: nil, unknownCode: nil),
            ExcludedPart(partkey: "DJIMIC3/S/s5_orig.wav", status: .skipped, errorCode: .llmFailed, unknownCode: nil),
        ]
        let text = render(
            try input(
                analysis: minimal, recordingKeys: [], excluded: excluded, recordedSeconds: nil, blockCount: 0,
                timeline: [], links: .empty))
        #expect(Array(text.utf8) == Array(Self.expectedC.utf8))
    }

    @Test("recorded は切り捨てで 2 桁を超えうる")
    func recordedFormat() {
        #expect(DailyNote.recorded(90_061.7) == "25:01:01")
        #expect(DailyNote.recorded(34_880.9) == "09:41:20")
        #expect(DailyNote.recorded(-1) == "00:00:00")
        #expect(DailyNote.recorded(0) == "00:00:00")
        #expect(DailyNote.recorded(nil) == "00:00:00")
        #expect(DailyNote.recorded(.nan) == "00:00:00")
    }

    @Test("タグは既定タグと合わせて正規化する")
    func tagsAreNormalized() {
        let tags = DailyNote.tags(
            analysisTags: ["VoiceDock", "DJI Mic", "a: b", "c \"d\"", "e\\f", "  ", "全角\u{3000}空白"],
            defaults: ["voice", "voicedock"])
        #expect(tags == ["voice", "voicedock", "DJI-Mic", "a:-b", "c-\"d\"", "e\\f", "全角-空白"])
    }

    @Test("タグの重複は casefold で除く")
    func tagsDedupeByCasefold() {
        #expect(
            DailyNote.tags(analysisTags: ["Voice", "STRASSE", "straße"], defaults: ["voice"]) == ["voice", "STRASSE"])
    }

    @Test("CE llm.analysis.order 節の順は設定の order")
    func sectionOrderFollowsConfig() throws {
        var config = NotesFixtures.appConfig()
        config.llm.analysis.order = ["ideas", "summary"]
        let found = headings(render(try input(), config))
        #expect(found == ["## Ideas", "## Summary", "## Sources", "## Links"])
        #expect(!found.contains("## Tasks"))
    }

    @Test("CE llm.analysis.sections.summary.heading 見出しは設定から")
    func headingsFromConfig() throws {
        var config = NotesFixtures.appConfig()
        config.llm.analysis.sections.summary.heading = "## 要約"
        let found = lines(render(try input(), config))
        #expect(found.contains("## 要約"))
        #expect(!found.contains("## Summary"))
    }

    @Test("CE llm.analysis.sections.timeline.heading 見出しは設定から")
    func ceTimelineHeading() throws {
        var config = NotesFixtures.appConfig()
        config.llm.analysis.sections.timeline.heading = "## 時系列"
        let found = lines(render(try input(timeline: try NotesFixtures.timelineFull), config))
        #expect(found.contains("## 時系列"))
        #expect(!found.contains("## Timeline"))
    }

    @Test("CE llm.analysis.sections.key_points.heading 見出しは設定から")
    func ceKeyPointsHeading() throws {
        var config = NotesFixtures.appConfig()
        config.llm.analysis.sections.keyPoints.heading = "## 要点"
        let found = lines(render(try input(), config))
        #expect(found.contains("## 要点"))
        #expect(!found.contains("## Key Points"))
    }

    @Test("CE llm.analysis.sections.tasks.heading 見出しは設定から")
    func ceTasksHeading() throws {
        var config = NotesFixtures.appConfig()
        config.llm.analysis.sections.tasks.heading = "## やること"
        let found = lines(render(try input(), config))
        #expect(found.contains("## やること"))
        #expect(!found.contains("## Tasks"))
    }

    @Test("CE llm.analysis.sections.decisions.heading 見出しは設定から")
    func ceDecisionsHeading() throws {
        var config = NotesFixtures.appConfig()
        config.llm.analysis.sections.decisions.heading = "## 決定"
        let found = lines(render(try input(), config))
        #expect(found.contains("## 決定"))
        #expect(!found.contains("## Decisions"))
    }

    @Test("CE llm.analysis.sections.ideas.heading 見出しは設定から")
    func ceIdeasHeading() throws {
        var config = NotesFixtures.appConfig()
        config.llm.analysis.sections.ideas.heading = "## 着想"
        let found = lines(render(try input(), config))
        #expect(found.contains("## 着想"))
        #expect(!found.contains("## Ideas"))
    }

    @Test("CE llm.analysis.sections.tags.heading 見出しは設定から")
    func ceTagsHeading() throws {
        var config = NotesFixtures.appConfig()
        config.llm.analysis.order.append("tags")
        config.llm.analysis.sections.tags.heading = "## タグ"
        let named = lines(render(try input(), config))
        #expect(named.contains("## タグ"))
        #expect(named.contains("- VoiceDock"))
        config.llm.analysis.sections.tags.heading = nil
        let fallback = lines(render(try input(), config))
        #expect(fallback.contains("## tags"))
        #expect(!fallback.contains("## タグ"))
    }

    @Test("CE llm.analysis.sections.timeline.enabled false なら Timeline を出さない")
    func ceTimelineEnabled() throws {
        let enabled = headings(render(try input(timeline: try NotesFixtures.timelineFull)))
        #expect(enabled.contains("## Timeline"))
        var config = NotesFixtures.appConfig()
        config.llm.analysis.sections.timeline.enabled = false
        let disabled = headings(render(try input(timeline: try NotesFixtures.timelineFull), config))
        #expect(
            disabled == [
                "## Summary", "## Key Points", "## Tasks", "## Decisions", "## Ideas", "## Sources", "## Links",
            ])
    }

    @Test(
        "無効な節は出さない",
        arguments: [
            ("key_points", "## Key Points"), ("tasks", "## Tasks"), ("decisions", "## Decisions"),
            ("ideas", "## Ideas"),
            ("timeline", "## Timeline"),
        ])
    func disabledSectionIsAbsent(section: String, heading: String) throws {
        var config = NotesFixtures.appConfig()
        switch section {
        case "key_points": config.llm.analysis.sections.keyPoints.enabled = false
        case "tasks": config.llm.analysis.sections.tasks.enabled = false
        case "decisions": config.llm.analysis.sections.decisions.enabled = false
        case "ideas": config.llm.analysis.sections.ideas.enabled = false
        default: config.llm.analysis.sections.timeline.enabled = false
        }
        #expect(headings(render(try input())).contains(heading))
        #expect(!headings(render(try input(), config)).contains(heading))
    }

    @Test(
        "空の節は見出しごと省く",
        arguments: [
            ("key_points", "## Key Points"), ("tasks", "## Tasks"), ("decisions", "## Decisions"),
            ("ideas", "## Ideas"),
        ])
    func emptySectionOmitted(section: String, heading: String) throws {
        let emptied: AnalysisView
        switch section {
        case "key_points": emptied = analysis(keyPoints: [])
        case "tasks": emptied = analysis(tasks: [])
        case "decisions": emptied = analysis(decisions: [])
        default: emptied = analysis(ideas: [])
        }
        let found = headings(render(try input(analysis: emptied)))
        #expect(!found.contains(heading))
        #expect(found.contains("## Summary"))
    }

    @Test("空の summary は節を省く")
    func emptySummaryOmitted() throws {
        let found = headings(render(try input(analysis: analysis(summary: "   "))))
        #expect(!found.contains("## Summary"))
        #expect(found.contains("## Timeline"))
    }

    @Test("期限のある task に 📅")
    func taskWithDue() throws {
        #expect(lines(render(try input())).contains("- [ ] Whisper の速度を実測する \u{1F4C5} 2026-09-05"))
    }

    @Test("期限の無い task に印を付けない")
    func taskWithoutDue() throws {
        let text = render(try input())
        #expect(text.contains("- [ ] DJI Mic 3 のマウント構造を確認する\n"))
        let line = lines(text).first { ScalarText.hasPrefix($0, "- [ ] DJI Mic 3") }
        #expect(line == "- [ ] DJI Mic 3 のマウント構造を確認する")
        #expect(line.map { !$0.unicodeScalars.contains("\u{1F4C5}") } == true)
    }

    @Test("Timeline は order の中の 1 節")
    func timelineIsOneOfTheSections() throws {
        let found = headings(render(try input()))
        let summary = try #require(found.firstIndex(of: "## Summary"))
        let timeline = try #require(found.firstIndex(of: "## Timeline"))
        let keyPoints = try #require(found.firstIndex(of: "## Key Points"))
        #expect(summary + 1 == timeline)
        #expect(timeline + 1 == keyPoints)
    }

    @Test("Timeline が空なら見出しも無い")
    func emptyTimelineOmitted() throws {
        #expect(!headings(render(try input(timeline: []))).contains("## Timeline"))
    }

    @Test("Sources は Raw へのリンク")
    func sourcesLinkToRaw() throws {
        #expect(render(try input()).contains("## Sources\n\n- [[2026-08-29 raw]]"))
    }

    @Test("Raw へのリンクが無ければ Sources も無い")
    func noSourcesWithoutRaw() throws {
        let links = LinkPlan(dailyNote: "[[2026-08-29]]", adjacent: [], tags: [], raw: [], dropped: [])
        let found = headings(render(try input(links: links)))
        #expect(!found.contains("## Sources"))
        #expect(found.contains("## Links"))
    }

    @Test("Links に #タグ を並べない")
    func plainTagsNotInLinks() throws {
        let all = lines(render(try input()))
        let start = try #require(all.firstIndex(of: "## Links"))
        let tail = Array(all[start...])
        #expect(!tail.contains("- #DJI-Mic"))
        #expect(!tail.contains { $0.unicodeScalars.contains("#") && !ScalarText.hasPrefix($0, "##") })
        #expect(tail.contains("- [[VoiceDock]]"))
    }

    @Test("題に : があっても frontmatter は壊れない")
    func titleWithColonIsSafe() throws {
        let text = render(try input(analysis: analysis(title: "a: b")))
        #expect(Frontmatter.parse(text) != nil)
        #expect(lines(text).contains("# a: b"))
    }

    @Test("崩れたタグでも frontmatter は読める")
    func hostileTagsParse() throws {
        let text = render(try input(analysis: analysis(tags: ["a: b", "#x", "[y]"])))
        let doc = try #require(Frontmatter.parse(text))
        let tags = try #require(doc["tags"] as? [String])
        #expect(tags == ["voice", "voicedock", "a:-b", "#x", "[y]"])
    }

    @Test("本文の行頭 --- は退避される")
    func leadingDashesEscaped() throws {
        let text = render(try input(analysis: analysis(summary: "---\n本文")))
        #expect(lines(text).contains("\\---"))
        #expect(Frontmatter.parse(text) != nil)
    }

    @Test("ファイル名に題を使わない")
    func fileNameNeverUsesTitle() throws {
        #expect(DailyNote.baseName(config: NotesFixtures.config(), day: try NotesFixtures.day) == "2026-08-29 Voice")
    }

    @Test("CE obsidian.wiki.filenameTemplate が Daily の基本名になる")
    func ceWikiFilenameTemplate() throws {
        var config = NotesFixtures.config()
        #expect(DailyNote.baseName(config: config, day: try NotesFixtures.day) == "2026-08-29 Voice")
        config.wiki.filenameTemplate = "{yyyymmdd} 声"
        #expect(DailyNote.baseName(config: config, day: try NotesFixtures.day) == "20260829 声")
    }

    @Test("CE obsidian.wiki.folderTemplate が Daily の置き場所になる")
    func ceWikiFolderTemplate() throws {
        var config = NotesFixtures.config()
        #expect(DailyNote.folder(config: config, day: try NotesFixtures.day) == "Daily/Voice/Wiki/20260829")
        config.wiki.folderTemplate = "Notes/{date}"
        #expect(DailyNote.folder(config: config, day: try NotesFixtures.day) == "Notes/2026-08-29")
    }

    @Test("CE obsidian.defaultTags が frontmatter の tags に入る")
    func ceDefaultTags() throws {
        let noTags = analysis(tags: [])
        let defaultDoc = try #require(Frontmatter.parse(render(try input(analysis: noTags))))
        #expect(defaultDoc["tags"] as? [String] == ["voice", "voicedock"])
        var config = NotesFixtures.appConfig()
        config.obsidian.defaultTags = ["mytag"]
        let doc = try #require(Frontmatter.parse(render(try input(analysis: noTags), config)))
        #expect(doc["tags"] as? [String] == ["mytag"])
    }

    @Test("Sources のリンク先は実際の Raw の名前（X-15）")
    func rawLinkNameUsesActualBasename() throws {
        let config = NotesFixtures.config()
        let day = try NotesFixtures.day
        #expect(
            DailyNote.rawLinkName(
                rawOutputPath: "Daily/Voice/Raw/20260829/2026-08-29 raw (2).md", config: config, day: day)
                == "2026-08-29 raw (2)")
        #expect(DailyNote.rawLinkName(rawOutputPath: nil, config: config, day: day) == "2026-08-29 raw")
        #expect(DailyNote.rawLinkName(rawOutputPath: "only.md", config: config, day: day) == "only")
        #expect(DailyNote.rawLinkName(rawOutputPath: "", config: config, day: day) == "")
    }

    @Test("DN-8 の見出しは設定から")
    func summaryHeadingFromConfig() {
        var config = NotesFixtures.appConfig()
        #expect(DailyNote.summaryHeading(config: config) == "## Summary")
        config.llm.analysis.sections.summary.heading = "## 要約"
        #expect(DailyNote.summaryHeading(config: config) == "## 要約")
        config.llm.analysis.sections.summary.heading = ""
        #expect(DailyNote.summaryHeading(config: config) == "## Summary")
        config.llm.analysis.sections.summary.heading = nil
        #expect(DailyNote.summaryHeading(config: config) == "## Summary")
    }
}
