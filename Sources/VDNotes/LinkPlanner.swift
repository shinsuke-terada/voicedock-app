// Daily ノートに付けるリンクを決める（PLAN §8.6 / NOTE-10 / PR-15。voicedock wiki.py:170-310）。文字列の差し込みはしない。例外を投げない。
import Foundation
import VDCore

public struct LinkPlan: Equatable, Sendable {
    /// "[[yyyy-MM-dd]]"
    public let dailyNote: String?
    /// 前日・翌日の "[[…]]"
    public let adjacent: [String]
    /// "[[名前]]" か "#名前"。入力の順
    public let tags: [String]
    /// Raw へのリンク。max_links の対象外
    public let raw: [String]
    /// 落とした候補（DEBUG ログ用）
    public let dropped: [String]

    public init(dailyNote: String?, adjacent: [String], tags: [String], raw: [String], dropped: [String]) {
        self.dailyNote = dailyNote
        self.adjacent = adjacent
        self.tags = tags
        self.raw = raw
        self.dropped = dropped
    }

    /// 全部 nil / 空
    public static let empty = LinkPlan(dailyNote: nil, adjacent: [], tags: [], raw: [], dropped: [])

    /// max_links に数える本数（Raw を含めない）
    public var counted: Int {
        (dailyNote != nil ? 1 : 0) + adjacent.count
            + tags.filter { ScalarText.hasPrefix($0, LinkPlanner.linkOpen) }.count
    }
}

public enum LinkPlanner {
    /// "[", "]", "|", "#", "^"
    public static let forbiddenScalars: Set<Unicode.Scalar> = ["[", "]", "|", "#", "^"]

    static let linkOpen = "[["
    static let linkClose = "]]"
    static let tagMark = "#"

    public static func plan(
        config: ObsidianConfig, day: LocalDate, tags: [String], index: VaultIndex?,
        selfName: String, nameForDay: (LocalDate) -> String, rawNames: [String]
    ) -> LinkPlan {
        let w = config.wiki
        var budget = w.maxLinks
        var dropped: [String] = []

        // 形の検査の後に自己参照（voicedock _usable と同じ）。落としたものは dropped に残す
        func usable(_ c: String) -> Bool {
            if !isLinkable(c, selfName: selfName) {
                dropped.append(c)
                return false
            }
            return true
        }

        // 1. 日付（usable を先に評価する。予算切れのときは dropped に入れない）
        var dailyNote: String?
        if w.linkDailyNote {
            let c = day.dashed
            if usable(c) && budget > 0 {
                dailyNote = link(c)
                budget -= 1
            }
        }

        // 2. 隣接日（実在は確かめない）
        var adjacent: [String] = []
        if w.linkAdjacentDays {
            for off in [-1, 1] {
                let c = nameForDay(day.adding(days: off))
                if !usable(c) { continue }
                if budget <= 0 {
                    dropped.append(c)
                    continue
                }
                adjacent.append(link(c))
                budget -= 1
            }
        }

        // 3. タグ（Vault に実在するものだけ [[]] にする。予算を超えたら #タグ で残す）
        var rendered: [String] = []
        for c in tags {
            if !usable(c) { continue }
            let existing = index?.contains(c) ?? false
            let wanted = w.linkTags && (existing || !w.linkOnlyExisting)
            if wanted && budget > 0 {
                rendered.append(link(c))
                budget -= 1
                continue
            }
            if wanted {
                dropped.append(c)
            }
            rendered.append(tag(c))
        }

        // 4. Raw（予算の対象外。自己参照の判定もしない。voicedock is_linkable）
        let raw = rawNames.filter { isWellFormed($0) }.map { link($0) }

        return LinkPlan(dailyNote: dailyNote, adjacent: adjacent, tags: rendered, raw: raw, dropped: dropped)
    }

    /// 00-api-map の形。形として使え（isWellFormed）、かつ自分自身（selfName）でないか
    public static func isLinkable(_ candidate: String, selfName: String) -> Bool {
        isWellFormed(candidate)
            && !PyText.scalarsEqual(VaultIndex.normalize(candidate), VaultIndex.normalize(selfName))
    }

    /// internal。voicedock の is_linkable（空・禁止文字だけを見る。自己参照は見ない）。Raw の候補に使う
    static func isWellFormed(_ candidate: String) -> Bool {
        let s = PyText.strip(candidate)
        if s.unicodeScalars.isEmpty { return false }
        return !s.unicodeScalars.contains { forbiddenScalars.contains($0) }
    }

    /// 候補は strip せずそのまま囲む（voicedock どおり）
    static func link(_ n: String) -> String {
        linkOpen + n + linkClose
    }

    static func tag(_ n: String) -> String {
        tagMark + n
    }
}
