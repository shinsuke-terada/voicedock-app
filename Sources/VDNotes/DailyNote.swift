// Daily ノート（整理済み）の描画（PLAN §8.6。voicedock daily.py:189-369 とバイト一致）。
import Foundation
import VDCore

/// 解析の結果のうち Daily ノートが使うもの。配列の節は nil = その節が無い（無効な節）、空配列 = 何も無い。
public struct AnalysisView: Sendable {
    public let title: String?
    public let summary: String?
    public let keyPoints: [String]?
    public let decisions: [String]?
    public let ideas: [String]?
    public let tags: [String]?
    public let tasks: [(text: String, due: String?)]?

    public init(
        title: String?, summary: String?, keyPoints: [String]?, decisions: [String]?, ideas: [String]?,
        tags: [String]?, tasks: [(text: String, due: String?)]?
    ) {
        self.title = title
        self.summary = summary
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.ideas = ideas
        self.tags = tags
        self.tasks = tasks
    }
}

/// 統合から外れた Part（FAILED か SKIPPED）。
public struct ExcludedPart: Sendable {
    public let partkey: String
    /// FAILED か SKIPPED
    public let status: PartStatus
    /// 既知のコード
    public let errorCode: ErrorCode?
    /// DB の error_code が ErrorCode に無い文字列のとき（errorCode は nil）
    public let unknownCode: String?

    public init(partkey: String, status: PartStatus, errorCode: ErrorCode?, unknownCode: String?) {
        self.partkey = partkey
        self.status = status
        self.errorCode = errorCode
        self.unknownCode = unknownCode
    }

    /// 理由の鍵: errorCode?.rawValue ?? unknownCode ?? ""（空文字も ""）
    var reasonKey: String {
        errorCode?.rawValue ?? unknownCode ?? ""
    }
}

/// Daily ノートを描くのに要るもの全部。
public struct DailyInput: Sendable {
    public let analysis: AnalysisView
    public let day: LocalDate
    public let sessionKey: String
    /// included（FAILED / SKIPPED 以外）の partkey を started_at, partkey 順
    public let recordingKeys: [String]
    /// FAILED / SKIPPED の Part を started_at, partkey 順
    public let excluded: [ExcludedPart]
    /// sessions.recorded_seconds（除外 Part も含む）
    public let recordedSeconds: Double?
    /// included で算出した Block の数
    public let blockCount: Int
    public let timeline: [TimelineBlock]
    public let links: LinkPlan
    /// Timeline の見出しの時刻に使う
    public let zone: ZonedTime

    public init(
        analysis: AnalysisView, day: LocalDate, sessionKey: String, recordingKeys: [String],
        excluded: [ExcludedPart], recordedSeconds: Double?, blockCount: Int, timeline: [TimelineBlock],
        links: LinkPlan, zone: ZonedTime
    ) {
        self.analysis = analysis
        self.day = day
        self.sessionKey = sessionKey
        self.recordingKeys = recordingKeys
        self.excluded = excluded
        self.recordedSeconds = recordedSeconds
        self.blockCount = blockCount
        self.timeline = timeline
        self.links = links
        self.zone = zone
    }
}

public enum DailyNote {
    public static let noteType = "voice-daily"
    public static let statusProcessed = "processed"
    /// U+1F4C5
    public static let dueMark = "📅"
    public static let defaultSummaryHeading = "## Summary"

    static let timelineSection = "timeline"
    static let summarySection = "summary"
    static let tasksSection = "tasks"
    /// Timeline の見出しの時刻の区切り（U+2013）
    static let rangeDash = "–"

    /// Daily ノート全体（frontmatter + 退避済みの本文）。純粋関数。
    public static func render(_ input: DailyInput, config: AppConfig) -> String {
        // 1. FAILED と SKIPPED を分ける（順序は保つ）
        let failed = input.excluded.filter { $0.status == .failed }
        let skipped = input.excluded.filter { $0.status != .failed }

        // 2. frontmatter
        let frontmatter = Frontmatter.render([
            (Frontmatter.keyType, .string(noteType)),
            (Frontmatter.keySessionKey, .string(input.sessionKey)),
            (Frontmatter.keyRecordingKeys, .array(input.recordingKeys)),
            (Frontmatter.keyFailedParts, .array(failed.map(\.partkey))),
            (Frontmatter.keySkippedParts, .array(skipped.map(\.partkey))),
            ("date", .string(input.day.dashed)),
            ("recorded", .string(recorded(input.recordedSeconds))),
            ("parts", .int(input.recordingKeys.count)),
            ("blocks", .int(input.blockCount)),
            ("status", .string(statusProcessed)),
            ("tags", .array(tags(analysisTags: input.analysis.tags, defaults: config.obsidian.defaultTags))),
        ])

        // 3. 題（strip しない）
        let title = nonEmpty(input.analysis.title) ?? input.day.dashed
        var lines = ["", "# " + title, ""]

        // 4. 警告行
        for warning in DailyWarnings.lines(failed: failed, skipped: skipped) {
            lines += [warning, ""]
        }

        // 5. 節（order の順。Timeline も 1 節）
        let analysis = config.llm.analysis
        for name in analysis.order {
            guard let section = analysis.sections.section(named: name), section.enabled else { continue }
            let heading = nonEmpty(section.heading) ?? "## " + name
            let rendered =
                name == timelineSection
                ? timelineLines(input.timeline, zone: input.zone) : sectionLines(name, input.analysis)
            if rendered.isEmpty { continue }
            lines += [heading, ""] + rendered
        }

        // 6. Sources と Links
        lines += sourcesLines(input.links) + linksLines(input.links)

        // 7. 本文（末尾の \n を全部落として 1 つ足す）と本文の行頭 --- の退避
        let body = ScalarText.trimTrailingLF(lines.joined(separator: "\n")) + "\n"
        return frontmatter + Frontmatter.escapeBody(body)
    }

    /// `.md` を含まない基本名（既定 `2026-08-29 Voice`）
    public static func baseName(config: ObsidianConfig, day: LocalDate) -> String {
        Sanitize.fileName(NoteTemplate.render(config.wiki.filenameTemplate, day: day), maxBytes: config.maxTitleBytes)
    }

    /// Vault からの相対フォルダ（sanitize しない。既定 `Daily/Voice/Wiki/20260829`）
    public static func folder(config: ObsidianConfig, day: LocalDate) -> String {
        NoteTemplate.render(config.wiki.folderTemplate, day: day)
    }

    /// 既定タグ + 解析のタグ。strip して U+0020 と U+3000 を `-` に置き換え、casefold で重複を除く（sanitize は通さない）。
    public static func tags(analysisTags: [String]?, defaults: [String]) -> [String] {
        let values = defaults + (analysisTags ?? [])
        // Python の set[str] と同じくスカラー列で比べる（Swift の String の == は正準等価で比べる）
        var seen = Set<[UInt32]>()
        var kept: [String] = []
        for value in values {
            let cleaned = ScalarText.replacing(PyText.strip(value), tagSpaceReplacements)
            if cleaned.unicodeScalars.isEmpty { continue }
            let key = PyText.casefold(cleaned).unicodeScalars.map(\.value)
            if seen.contains(key) { continue }
            seen.insert(key)
            kept.append(cleaned)
        }
        return kept
    }

    /// タグの中の空白（U+0020 と U+3000 の 2 つだけ）を `-` にする
    static let tagSpaceReplacements: [Unicode.Scalar: Unicode.Scalar] = [" ": "-", "\u{3000}": "-"]

    /// `HH:MM:SS`（0 方向へ切り捨て。時は 2 桁を超えうる）。nil・負・有限でない・Int に収まらない → `00:00:00`
    public static func recorded(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0, let t = Int(exactly: seconds.rounded(.towardZero))
        else { return "00:00:00" }
        return String(format: "%02ld:%02ld:%02ld", t / 3600, t / 60 % 60, t % 60)
    }

    /// DN-8 の見出し: sections.summary.heading が nil か空でなければそれ、でなければ "## Summary"
    public static func summaryHeading(config: AppConfig) -> String {
        nonEmpty(config.llm.analysis.sections.summary.heading) ?? defaultSummaryHeading
    }

    /// `## Sources` のリンク先: raw_output_path の basename から ".md" を除いたもの。nil なら RawNote.baseName（X-15）
    public static func rawLinkName(rawOutputPath: String?, config: ObsidianConfig, day: LocalDate) -> String {
        guard let rawOutputPath else { return RawNote.baseName(config: config, day: day) }
        let scalars = Array(rawOutputPath.unicodeScalars)
        let start = (scalars.lastIndex(of: "/").map { $0 + 1 }) ?? 0
        let name = ScalarText.string(Array(scalars[start...]))
        guard ScalarText.hasSuffix(name, markdownSuffix) else { return name }
        let nameScalars = Array(name.unicodeScalars)
        return ScalarText.string(Array(nameScalars[0..<(nameScalars.count - markdownSuffix.unicodeScalars.count)]))
    }

    static let markdownSuffix = ".md"

    /// nil でなく空でなければそのまま、でなければ nil
    static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.unicodeScalars.isEmpty else { return nil }
        return s
    }

    /// Timeline 以外の節の行。空なら見出しごと省く。
    static func sectionLines(_ name: String, _ a: AnalysisView) -> [String] {
        switch name {
        case summarySection:
            let text = PyText.strip(a.summary ?? "")
            return text.unicodeScalars.isEmpty ? [] : [text, ""]
        case tasksSection:
            guard let tasks = a.tasks, !tasks.isEmpty else { return [] }
            return tasks.map { task in
                "- [ ] " + task.text + (nonEmpty(task.due).map { " " + dueMark + " " + $0 } ?? "")
            } + [""]
        default:
            let values: [String]?
            switch name {
            case "key_points": values = a.keyPoints
            case "decisions": values = a.decisions
            case "ideas": values = a.ideas
            case "tags": values = a.tags
            default: values = nil
            }
            guard let values, !values.isEmpty else { return [] }
            return values.map { "- " + $0 } + [""]
        }
    }

    /// Timeline の行。見出しの時刻は設定のタイムゾーンの規則で描く（PLAN §5.7・X-32）。
    static func timelineLines(_ blocks: [TimelineBlock], zone: ZonedTime) -> [String] {
        var lines: [String] = []
        for block in blocks {
            lines += ["### " + hhmm(block.start, zone) + rangeDash + hhmm(block.end, zone), ""]
            lines += block.lines.map { "- " + $0 }
            lines += [""]
        }
        return lines
    }

    static func hhmm(_ i: Instant, _ zone: ZonedTime) -> String {
        ISOWallClock.hhmm(zone.iso(i)) ?? ""
    }

    /// `## Sources`（Raw へのリンク）。Raw へのリンクが無ければ出さない。
    static func sourcesLines(_ links: LinkPlan) -> [String] {
        if links.raw.isEmpty { return [] }
        return ["## Sources", ""] + links.raw.map { "- " + $0 } + [""]
    }

    /// `## Links`（日付・隣接日・`[[` で始まるタグ）。`#タグ` は並べない。
    static func linksLines(_ links: LinkPlan) -> [String] {
        let values =
            [links.dailyNote].compactMap { $0 }.filter { !$0.unicodeScalars.isEmpty }
            + links.adjacent.filter { !$0.unicodeScalars.isEmpty }
            + links.tags.filter { ScalarText.hasPrefix($0, LinkPlanner.linkOpen) }
        if values.isEmpty { return [] }
        return ["## Links", ""] + values.map { "- " + $0 } + [""]
    }
}
