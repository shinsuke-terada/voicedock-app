// Part の正規化 transcript（transcripts/parts/<slug>.json）の型と読み書き（PLAN §8.4）。
import Foundation

public struct TranscriptSegment: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    /// 話者のラベル（`SpeakerLabel`。PLAN §8.4.1。F-89）。話者分離をしていない区間は nil。
    public let speaker: String?

    public init(start: Double, end: Double, text: String, speaker: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}

public struct PartTranscript: Equatable, Sendable {
    public let partkey: String
    public let language: String
    public let durationSeconds: Double?
    /// Part の started_at（ISO 文字列）をそのまま
    public let startedAt: String
    public let text: String
    public let segments: [TranscriptSegment]

    public init(
        partkey: String, language: String, durationSeconds: Double?, startedAt: String, text: String,
        segments: [TranscriptSegment]
    ) {
        self.partkey = partkey
        self.language = language
        self.durationSeconds = durationSeconds
        self.startedAt = startedAt
        self.text = text
        self.segments = segments
    }
}

public enum PartTranscriptCodec {
    /// 合格条件の 6 つのキー（PLAN §8.4）。
    static let requiredKeys = ["partkey", "language", "duration_seconds", "started_at", "text", "segments"]

    /// transcripts/parts/<slug>.json の中身（PLAN §8.4）: PyJSON の indent 2 ＋ 末尾改行。
    /// キーの順は partkey, language, duration_seconds, started_at, text, segments（各要素 start, end, text）。
    /// 区間の speaker は非 nil のときだけ text の後に書く（F-89。nil なら F-89 の前とバイト単位で同じ）。
    public static func encode(_ t: PartTranscript) -> Data {
        PyJSON.fileData(
            .object([
                ("partkey", .string(t.partkey)), ("language", .string(t.language)),
                ("duration_seconds", t.durationSeconds.map { .double($0) } ?? .null),
                ("started_at", .string(t.startedAt)), ("text", .string(t.text)),
                ("segments", .array(t.segments.map(segmentObject))),
            ]))
    }

    private static func segmentObject(_ segment: TranscriptSegment) -> PyJSONValue {
        var pairs: [(String, PyJSONValue)] = [
            ("start", .double(segment.start)), ("end", .double(segment.end)), ("text", .string(segment.text)),
        ]
        if let speaker = segment.speaker {
            pairs.append(("speaker", .string(speaker)))
        }
        return .object(pairs)
    }

    /// 読み戻し。合格条件（PLAN §8.4）を 1 つでも満たさなければ nil（例外にしない）。
    /// voicedock は bool を数として受け、partkey を文字列化していた。本アプリは厳しく読む。
    public static func decode(_ data: Data) -> PartTranscript? {
        guard let document = PyJSON.parse(data) as? [String: Any],
            requiredKeys.allSatisfy({ document[$0] != nil }),
            let entries = document["segments"] as? [Any]
        else { return nil }
        var segments: [TranscriptSegment] = []
        for entry in entries {
            guard let item = entry as? [String: Any], let start = number(item["start"]), let end = number(item["end"]),
                let text = item["text"] as? String
            else { return nil }
            // speaker は在れば文字列であること（F-89）。無ければ nil
            let speaker: String?
            if let value = item["speaker"] {
                guard let label = value as? String else { return nil }
                speaker = label
            } else {
                speaker = nil
            }
            segments.append(TranscriptSegment(start: start, end: end, text: text, speaker: speaker))
        }
        guard let text = document["text"] as? String, let startedAt = document["started_at"] as? String,
            let language = document["language"] as? String, let partkey = document["partkey"] as? String
        else { return nil }
        let duration: Double?
        if document["duration_seconds"] is NSNull {
            duration = nil
        } else if let value = number(document["duration_seconds"]) {
            duration = value
        } else {
            return nil
        }
        return PartTranscript(
            partkey: partkey, language: language, durationSeconds: duration, startedAt: startedAt, text: text,
            segments: segments)
    }

    /// 数（`PyJSON.isBool` が偽の `NSNumber`）で、秒として読める（F-71: 有限で絶対値が 10 億秒以下）なら Double。
    /// NaN・±Infinity・巨大な秒は「読めない」（`PyJSON` は NaN / Infinity を受けるので、ここで弾く）。
    private static func number(_ value: Any?) -> Double? {
        guard let value, let number = value as? NSNumber, !PyJSON.isBool(number) else { return nil }
        let seconds = number.doubleValue
        return SecondsToMillis.isReadable(seconds) ? seconds : nil
    }
}
