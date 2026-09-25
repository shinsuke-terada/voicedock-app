// Session の統合結果の型・指紋（PLAN §8.5）・連続録音の塊（Block。PLAN §5.6）。
import Foundation

public struct AbsoluteSegment: Equatable, Sendable {
    public let at: Instant
    public let endAt: Instant
    public let text: String
    /// 話者のラベル（`SpeakerLabel`。PLAN §8.4.1。F-89）。話者分離をしていない区間は nil。
    public let speaker: String?

    public init(at: Instant, endAt: Instant, text: String, speaker: String? = nil) {
        self.at = at
        self.endAt = endAt
        self.text = text
        self.speaker = speaker
    }
}

public struct TimeBlock: Equatable, Sendable {
    public let start: Instant
    public let end: Instant

    public init(start: Instant, end: Instant) {
        self.start = start
        self.end = end
    }
}

public struct SessionTranscript: Equatable, Sendable {
    public let dayDate: LocalDate
    /// (at, endAt) で安定ソート済み（作るのは VDPipeline。PLAN §5.6）
    public let segments: [AbsoluteSegment]
    public let blocks: [TimeBlock]
    public let excludedPartkeys: [String]

    public init(dayDate: LocalDate, segments: [AbsoluteSegment], blocks: [TimeBlock], excludedPartkeys: [String]) {
        self.dayDate = dayDate
        self.segments = segments
        self.blocks = blocks
        self.excludedPartkeys = excludedPartkeys
    }
}

public enum TranscriptFingerprint {
    /// voicedock session.py:60-93 と同一定義（PLAN §8.5）。除外 Part・プロンプト・設定は混ぜない。
    public static func of(_ t: SessionTranscript, zone: ZonedTime) -> String {
        FileHasher.sha256(Data(payload(t, zone: zone).utf8))
    }

    /// 指紋の元の文字列（PyJSON のコンパクト形式・sortKeys。golden の照合に使う）。
    /// 区間の speaker は非 nil のときだけ足す（F-89。nil の区間は F-89 の前と同じ）。
    static func payload(_ t: SessionTranscript, zone: ZonedTime) -> String {
        let value = PyJSONValue.object([
            ("segments", .array(t.segments.map { segmentObject($0, zone: zone) })),
            ("blocks", .array(t.blocks.map { .array([.string(zone.iso($0.start)), .string(zone.iso($0.end))]) })),
        ])
        return PyJSON.dumpsCompact(value, sortKeys: true)
    }

    private static func segmentObject(_ segment: AbsoluteSegment, zone: ZonedTime) -> PyJSONValue {
        var pairs: [(String, PyJSONValue)] = [
            ("at", .string(zone.iso(segment.at))), ("end_at", .string(zone.iso(segment.endAt))),
            ("text", .string(segment.text)),
        ]
        if let speaker = segment.speaker {
            pairs.append(("speaker", .string(speaker)))
        }
        return .object(pairs)
    }
}

public enum BlockComputer {
    /// 連続録音の塊（PLAN §5.6。voicedock session.py:329-367）。入力の順は問わない（中で並べる）。
    public static func blocks(_ parts: [(startedAt: Instant, endedAt: Instant?)], gapSeconds: Int) -> [TimeBlock] {
        // 1. 安定ソート（voicedock の (started_at, ended_at or "") と同じ順。nil は同じ開始の中で先）
        let sorted = parts.enumerated().sorted { a, b in
            let ka = (
                a.element.startedAt.epochMillis, a.element.endedAt == nil ? 0 : 1, a.element.endedAt?.epochMillis ?? 0
            )
            let kb = (
                b.element.startedAt.epochMillis, b.element.endedAt == nil ? 0 : 1, b.element.endedAt?.epochMillis ?? 0
            )
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
        // 2. 空なら []
        guard let first = sorted.first else { return [] }
        // 3. 最初の Part
        var start = first.startedAt
        var end = first.endedAt ?? first.startedAt
        var unknownEnd = first.endedAt == nil
        var result: [TimeBlock] = []
        // 4. 以降の各 Part
        for part in sorted.dropFirst() {
            let gap = part.startedAt - end
            if unknownEnd || gap > Int64(gapSeconds) * 1000 {
                result.append(TimeBlock(start: start, end: end))
                start = part.startedAt
                end = part.endedAt ?? part.startedAt
                unknownEnd = part.endedAt == nil
            } else {
                unknownEnd = part.endedAt == nil
                end = max(end, part.endedAt ?? part.startedAt)
            }
        }
        // 5. 最後の塊
        result.append(TimeBlock(start: start, end: end))
        return result
    }
}
