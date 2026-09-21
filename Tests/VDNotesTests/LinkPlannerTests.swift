// リンク計画（PLAN §8.6 / NOTE-10 / PR-15。T-27 §5.5）。
import Foundation
import Testing
import VDCore

@testable import VDNotes

@Suite("LinkPlanner")
struct LinkPlannerTests {
    static let selfName = "2026-09-12 Voice"

    func day(_ dashed: String = "2026-09-12") throws -> LocalDate {
        try #require(LocalDate(dashed: dashed))
    }

    func index(_ names: [String]) -> VaultIndex {
        VaultIndex(names: Set(names.map(VaultIndex.normalize)), builtAt: .zero)
    }

    func plan(
        config: ObsidianConfig = NotesFixtures.config(), day: LocalDate? = nil, tags: [String] = [],
        index: VaultIndex? = nil, selfName: String = LinkPlannerTests.selfName,
        nameForDay: (LocalDate) -> String = { "\($0.dashed) Voice" }, rawNames: [String] = []
    ) throws -> LinkPlan {
        LinkPlanner.plan(
            config: config, day: try day ?? self.day(), tags: tags, index: index, selfName: selfName,
            nameForDay: nameForDay, rawNames: rawNames)
    }

    func config(_ change: (inout WikiNoteConfig) -> Void) -> ObsidianConfig {
        var config = NotesFixtures.config()
        change(&config.wiki)
        return config
    }

    @Test("voicedock と同じ計画")
    func planMatchesVoicedock() throws {
        let result = try plan(
            day: try day("2026-08-29"), tags: ["VoiceDock", "none", "a#b", "2026-08-29 Voice"],
            index: index(["voicedock"]), selfName: "2026-08-29 Voice", rawNames: ["2026-08-29 raw"])
        #expect(
            result
                == LinkPlan(
                    dailyNote: "[[2026-08-29]]", adjacent: ["[[2026-08-28 Voice]]", "[[2026-08-30 Voice]]"],
                    tags: ["[[VoiceDock]]", "#none"], raw: ["[[2026-08-29 raw]]"], dropped: ["a#b", "2026-08-29 Voice"])
        )
    }

    @Test("禁止文字を含む候補は落とす")
    func forbiddenCharactersDropped() throws {
        let candidates = ["a[b", "a]b", "a|b", "a#b", "a^b"]
        let result = try plan(tags: candidates, index: index(candidates))
        #expect(result.tags == [])
        #expect(result.dropped == candidates)
    }

    @Test("空白だけの候補は落とす")
    func blankDropped() throws {
        for c in ["", "   ", "\n"] {
            #expect(!LinkPlanner.isLinkable(c, selfName: Self.selfName))
        }
        #expect(try plan(tags: ["", "   ", "\n"], index: index([])).tags == [])
    }

    @Test("自分自身は落とす（大小無視）")
    func selfReferenceDropped() throws {
        #expect(try plan(tags: [Self.selfName], index: index([Self.selfName])).tags == [])
        #expect(try plan(tags: [Self.selfName.uppercased()], index: index([Self.selfName])).tags == [])
        #expect(try plan(tags: ["2026-09-12 VOICE"]).dropped.contains("2026-09-12 VOICE"))
    }

    @Test("索引に在ればリンク")
    func existingBecomesLink() throws {
        #expect(try plan(tags: ["VoiceDock"], index: index(["voicedock"])).tags == ["[[VoiceDock]]"])
    }

    @Test("索引に無ければ #タグ")
    func missingStaysTag() throws {
        #expect(try plan(tags: ["存在しない"], index: index(["voicedock"])).tags == ["#存在しない"])
    }

    @Test("順序は入力のまま")
    func mixedKeepOrder() throws {
        #expect(
            try plan(tags: ["存在しない", "DJI", "これも無い"], index: index(["dji"])).tags == [
                "#存在しない", "[[DJI]]", "#これも無い",
            ])
    }

    @Test("CE obsidian.wiki.linkOnlyExisting が偽なら全部リンク")
    func linkOnlyExistingFalse() throws {
        #expect(try plan(tags: ["存在しない"], index: index([])).tags == ["#存在しない"])
        let off = config { $0.linkOnlyExisting = false }
        #expect(try plan(config: off, tags: ["存在しない"], index: index([])).tags == ["[[存在しない]]"])
    }

    @Test("CE obsidian.wiki.linkTags が偽ならタグのまま")
    func linkTagsFalse() throws {
        #expect(try plan(tags: ["VoiceDock"], index: index(["voicedock"])).tags == ["[[VoiceDock]]"])
        let off = config { $0.linkTags = false }
        #expect(try plan(config: off, tags: ["VoiceDock"], index: nil).tags == ["#VoiceDock"])
    }

    @Test("日付は 1 つ")
    func dateLinkedOnce() throws {
        #expect(try plan().dailyNote == "[[2026-09-12]]")
    }

    @Test("前日と翌日")
    func adjacentDays() throws {
        #expect(try plan().adjacent == ["[[2026-09-11 Voice]]", "[[2026-09-13 Voice]]"])
    }

    @Test("月の境目")
    func monthBoundary() throws {
        #expect(
            try plan(day: try day("2026-03-01"), selfName: "2026-03-01 Voice").adjacent == [
                "[[2026-02-28 Voice]]", "[[2026-03-02 Voice]]",
            ])
    }

    @Test("隣接日の名前は呼び手が決める")
    func adjacentNamesFromCaller() throws {
        #expect(
            try plan(nameForDay: { "Journal \($0.dashed)" }).adjacent == [
                "[[Journal 2026-09-11]]", "[[Journal 2026-09-13]]",
            ])
    }

    @Test("CE obsidian.wiki.linkDailyNote が偽なら日付のリンクを作らない")
    func ceLinkDailyNoteOff() throws {
        #expect(try plan().dailyNote == "[[2026-09-12]]")
        #expect(try plan(config: config { $0.linkDailyNote = false }).dailyNote == nil)
    }

    @Test("CE obsidian.wiki.linkAdjacentDays が偽なら隣接日のリンクを作らない")
    func ceLinkAdjacentDaysOff() throws {
        #expect(try plan().adjacent.count == 2)
        #expect(try plan(config: config { $0.linkAdjacentDays = false }).adjacent == [])
    }

    @Test("CE obsidian.wiki.maxLinks 上限で切る")
    func capped() throws {
        let tags = (0..<10).map { "Tag\($0)" }
        let capped = try plan(config: config { $0.maxLinks = 5 }, tags: tags, index: index(tags))
        #expect(capped.counted == 5)
        #expect(capped.tags.filter { $0.hasPrefix("[[") } == ["[[Tag0]]", "[[Tag1]]"])
        #expect(capped.tags[2] == "#Tag2")
        let wide = try plan(tags: tags, index: index(tags))
        #expect(wide.tags == tags.map { "[[\($0)]]" })
        #expect(wide.counted == 13)
    }

    @Test("Raw は上限の対象外")
    func rawNotCounted() throws {
        let rawNames = (0..<32).map { "raw \($0)" }
        let result = try plan(config: config { $0.maxLinks = 1 }, rawNames: rawNames)
        #expect(result.raw.count == 32)
        #expect(result.counted == 1)
    }

    @Test("上限を超えたタグは #タグ で残す")
    func capKeepsTags() throws {
        let result = try plan(config: config { $0.maxLinks = 3 }, tags: ["Kept"], index: index(["Kept"]))
        #expect(result.tags == ["#Kept"])
        #expect(result.dropped.contains("Kept"))
    }

    @Test("maxLinks 0")
    func zeroMaxLinks() throws {
        let result = try plan(
            config: config { $0.maxLinks = 0 }, tags: ["Tag"], index: index(["Tag"]), rawNames: ["raw"])
        #expect(result.dailyNote == nil)
        #expect(result.adjacent == [])
        #expect(result.tags == ["#Tag"])
        #expect(result.raw == ["[[raw]]"])
        #expect(result.counted == 0)
    }

    @Test("予算切れの日付は dropped に入れない")
    func exhaustedDailyNotDropped() throws {
        let result = try plan(config: config { $0.maxLinks = 0 })
        #expect(!result.dropped.contains("2026-09-12"))
        #expect(result.dropped.contains("2026-09-11 Voice"))
    }

    @Test("タグも Raw も無ければ Raw とタグは空")
    func emptyInputs() throws {
        let result = try plan()
        #expect(result.tags == [])
        #expect(result.raw == [])
        #expect(result.dropped == [])
        #expect(LinkPlan.empty.counted == 0)
    }
}
