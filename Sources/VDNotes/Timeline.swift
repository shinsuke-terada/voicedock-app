// Timeline の組み立て・保存形式（PLAN §8.6。voicedock daily.py:88-183, 440-521）。時刻は LLM に作らせない。
import Foundation
import VDCore

public struct TimelineBlock: Equatable, Sendable {
    public let start: Instant
    public let end: Instant
    public let lines: [String]

    public init(start: Instant, end: Instant, lines: [String]) {
        self.start = start
        self.end = end
        self.lines = lines
    }
}

public enum Timeline {
    /// 保存形式の版（transcript_sha256 を持つ形）
    public static let schema = 2

    static let keySchema = "schema"
    static let keyFingerprint = "transcript_sha256"
    static let keyBlocks = "blocks"
    static let keyStartAt = "start_at"
    static let keyEndAt = "end_at"
    static let keyLines = "lines"

    /// Map の結果があればチャンクごと、無ければ Block ごとに summary の文を繰り返す（追加の LLM 呼び出しはしない）。
    public static func build(
        partials: [AnalysisView], chunks: [(start: Instant, end: Instant)], transcript: SessionTranscript,
        summary: String?
    ) -> [TimelineBlock] {
        if !partials.isEmpty && !chunks.isEmpty {
            return zip(partials, chunks).compactMap { partial, chunk in
                let lines = points(partial)
                return lines.isEmpty ? nil : TimelineBlock(start: chunk.start, end: chunk.end, lines: lines)
            }
        }
        let s = sentences(summary ?? "")
        if s.isEmpty { return [] }
        var blocks = transcript.blocks
        if blocks.isEmpty, let first = transcript.segments.first,
            let last = transcript.segments.map(\.endAt).max()
        {
            blocks = [TimeBlock(start: first.at, end: last)]
        }
        return blocks.map { TimelineBlock(start: $0.start, end: $0.end, lines: s) }
    }

    /// key_points が nil でなく空でなければそれ、でなければ summary の文
    static func points(_ p: AnalysisView) -> [String] {
        if let keyPoints = p.keyPoints, !keyPoints.isEmpty {
            return keyPoints
        }
        return sentences(p.summary ?? "")
    }

    /// `。` の直後で割り、各行を strip して空を捨てる。
    /// 置換は `.literal`（結合文字が続く `。` も置換する。Python の str.replace と同じ）。
    public static func sentences(_ text: String) -> [String] {
        PyText.splitLines(text.replacingOccurrences(of: "。", with: "。\n", options: .literal))
            .map { PyText.strip($0) }
            .filter { !$0.unicodeScalars.isEmpty }
    }

    /// `<slug>.timeline.json` の中身（indent 2 ＋ 末尾改行。キーはこの順）。書き込みは呼び手が AtomicFile で行う。
    public static func encode(_ blocks: [TimelineBlock], fingerprint: String, zone: ZonedTime) -> Data {
        PyJSON.fileData(
            .object([
                (keySchema, .int(Int64(schema))),
                (keyFingerprint, .string(fingerprint)),
                (
                    keyBlocks,
                    .array(
                        blocks.map { block in
                            .object([
                                (keyStartAt, .string(zone.iso(block.start))),
                                (keyEndAt, .string(zone.iso(block.end))),
                                (keyLines, .array(block.lines.map { .string($0) })),
                            ])
                        })
                ),
            ]))
    }

    /// 保存形式を読む。形が違えば空。要素の不正はその要素だけ飛ばす。例外を投げない（PLAN §5.7・F-45）。
    public static func decode(_ data: Data, fingerprint: String, zone: ZonedTime) -> [TimelineBlock] {
        guard case .object(let top)? = PyJSON.decode(data) else { return [] }
        switch member(top, keySchema) {
        case .int(let n)? where n == Int64(schema):
            break
        case .double(let d)? where d == Double(schema):
            break
        default:
            return []
        }
        guard case .string(let stored)? = member(top, keyFingerprint), PyText.scalarsEqual(stored, fingerprint)
        else { return [] }
        guard case .array(let items)? = member(top, keyBlocks) else { return [] }
        var blocks: [TimelineBlock] = []
        for item in items {
            guard case .object(let o) = item,
                case .string(let startText)? = member(o, keyStartAt), let start = zone.parseISO(startText),
                case .string(let endText)? = member(o, keyEndAt), let end = zone.parseISO(endText),
                case .array(let lines)? = member(o, keyLines)
            else { continue }
            blocks.append(
                TimelineBlock(start: start, end: end, lines: lines.map { PyStr.describe($0.foundationObject) }))
        }
        return blocks
    }

    /// オブジェクトのメンバー（重複キーは decode が後勝ちで 1 つにしている）
    static func member(_ o: [(String, PyJSONValue)], _ key: String) -> PyJSONValue? {
        o.first { PyText.scalarsEqual($0.0, key) }?.1
    }
}
