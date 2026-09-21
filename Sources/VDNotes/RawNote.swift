// Raw ノート（文字起こし生データ）の描画（PLAN §8.6。voicedock raw.py:135-218 とバイト一致）。
import Foundation
import VDCore

public struct RawPart: Sendable {
    public let partkey: String
    /// DB の recordings.started_at（オフセット付き ISO。例 2026-08-29T07:12:04+09:00）
    public let startedAt: String
    /// DB の recordings.ended_at
    public let endedAt: String?
    /// at = started_at + start（ミリ秒）、与えられた順に描く
    public let segments: [AbsoluteSegment]
    /// startedAt を Instant に直すため（並べ替え）
    public let zone: ZonedTime

    public init(partkey: String, startedAt: String, endedAt: String?, segments: [AbsoluteSegment], zone: ZonedTime) {
        self.partkey = partkey
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.segments = segments
        self.zone = zone
    }
}

public enum RawNote {
    public static let noteType = "voice-raw"
    public static let sourceLabel = "DJI Mic 3"
    public static let intro = "> 自動文字起こしの生データ。未編集。"

    /// `# 2026-08-29 の文字起こし（生データ）`（括弧は U+FF08 / U+FF09）
    public static func title(_ day: LocalDate) -> String {
        "# " + day.dashed + " の文字起こし（生データ）"
    }

    /// Raw ノート全体（frontmatter + 退避済みの本文）。純粋関数。渡された Part を全部描く（選別は呼び手。T-29）。
    public static func render(parts: [RawPart], day: LocalDate, sessionKey: String, config: ObsidianConfig) -> String {
        // 1. 並べ替え（Python の sorted(key=(started_at, partkey))。瞬間で比べる）
        let ordered = parts.enumerated()
            .sorted { lhs, rhs in
                let a = sortKey(lhs.element)
                let b = sortKey(rhs.element)
                if a.0 != b.0 { return a.0 < b.0 }
                if a.1 != b.1 { return precedes(a.1, b.1) }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        // 2. frontmatter
        let frontmatter = Frontmatter.render([
            (Frontmatter.keyType, .string(noteType)),
            (Frontmatter.keySessionKey, .string(sessionKey)),
            (Frontmatter.keyRecordingKeys, .array(ordered.map(\.partkey))),
            ("date", .string(day.dashed)),
            ("parts", .int(ordered.count)),
            ("source", .string(sourceLabel)),
        ])

        // 3. 本文の行
        var lines = ["", title(day), "", intro, ""]
        for part in ordered {
            if config.raw.partBoundaryHeading {
                let range = hhmm(part.startedAt) + "–" + (part.endedAt.map(hhmm) ?? "")
                lines += ["## " + range, ""]
            }
            lines += segmentLines(part, interval: config.raw.timestampIntervalSeconds)
        }

        // 4. 本文（末尾の \n を全部落として 1 つ足す）
        let body = ScalarText.trimTrailingLF(lines.joined(separator: "\n")) + "\n"
        // 5. 本文の行頭 --- を退避する
        return frontmatter + Frontmatter.escapeBody(body)
    }

    /// `.md` を含まない基本名（既定 `2026-08-29 raw`）
    public static func baseName(config: ObsidianConfig, day: LocalDate) -> String {
        Sanitize.fileName(NoteTemplate.render(config.raw.filenameTemplate, day: day), maxBytes: config.maxTitleBytes)
    }

    /// Vault からの相対フォルダ（sanitize しない。既定 `Daily/Voice/Raw/20260829`）
    public static func folder(config: ObsidianConfig, day: LocalDate) -> String {
        NoteTemplate.render(config.raw.folderTemplate, day: day)
    }

    /// 1 Part の区間。interval 秒ごとに実際の区間の時刻で `###` を差し込む（NOTE-04）。0 なら見出しを入れない。
    static func segmentLines(_ part: RawPart, interval: Int) -> [String] {
        let fixed = ZonedTime(fixedOffsetSeconds: offsetOf(part.startedAt))
        var lines: [String] = []
        var chunk: [String] = []
        var nextMark: Instant?
        for seg in part.segments {
            let text = PyText.strip(seg.text)
            if text.unicodeScalars.isEmpty { continue }
            if interval > 0 && (nextMark.map { seg.at >= $0 } ?? true) {
                if !chunk.isEmpty {
                    lines += [chunk.joined(separator: " "), ""]
                    chunk = []
                }
                lines += ["### " + hhmmss(seg.at, fixed), ""]
                nextMark = seg.at.adding(seconds: interval)
            }
            chunk.append(text)
        }
        if !chunk.isEmpty {
            lines += [chunk.joined(separator: " "), ""]
        }
        return lines
    }

    /// 並べ替えの鍵（started_at の瞬間、partkey）。読めない started_at は最小。
    static func sortKey(_ part: RawPart) -> (Int64, String) {
        (part.zone.parseISO(part.startedAt)?.epochMillis ?? Int64.min, part.partkey)
    }

    /// Python の文字列の比較（スカラー値の辞書式順）。
    static func precedes(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.map(\.value).lexicographicallyPrecedes(b.unicodeScalars.map(\.value))
    }

    /// 保存された文字列の壁時計の HH:MM（秒は捨てる）
    static func hhmm(_ iso: String) -> String {
        ISOWallClock.hhmm(iso) ?? ""
    }

    /// Part の started_at の固定オフセットでの壁時計の HH:MM:SS（X-32）
    static func hhmmss(_ instant: Instant, _ fixed: ZonedTime) -> String {
        ISOWallClock.hhmmss(fixed.iso(instant)) ?? ""
    }

    /// 文字列の末尾が `Z` なら 0。末尾 6 スカラーが `±HH:MM` なら `±(HH*3600 + MM*60)`。どちらでもなければ 0
    static func offsetOf(_ iso: String) -> Int {
        let scalars = Array(iso.unicodeScalars)
        if scalars.last == "Z" { return 0 }
        guard scalars.count >= 6 else { return 0 }
        let tail = Array(scalars[(scalars.count - 6)...])
        guard tail[0] == "+" || tail[0] == "-", tail[3] == ":",
            let hours = twoDigits(tail[1], tail[2]), let minutes = twoDigits(tail[4], tail[5])
        else { return 0 }
        let magnitude = hours * 3600 + minutes * 60
        return tail[0] == "-" ? -magnitude : magnitude
    }

    /// ASCII の 2 桁の数字。数字でなければ nil。
    static func twoDigits(_ high: Unicode.Scalar, _ low: Unicode.Scalar) -> Int? {
        let digits: ClosedRange<Unicode.Scalar> = "0"..."9"
        guard digits.contains(high), digits.contains(low) else { return nil }
        return Int(high.value - 48) * 10 + Int(low.value - 48)
    }
}
