// whisper.cpp v1.9.4 の -oj の生 JSON を読む（PLAN §8.4 手順 7。voicedock transcribe.py:333-389）。
import Foundation
import VDCore

public enum WhisperOutputParser {
    /// JSON として読めない（またはトップレベルが null）なら nil。それ以外は壊れた要素を飛ばして必ず結果を返す。
    public static func parse(
        _ data: Data, fallbackLanguage: String
    ) -> (language: String, text: String, segments: [TranscriptSegment])? {
        guard let document = PyJSON.decode(data), document != .null else { return nil }
        let body: [(String, PyJSONValue)]
        if case .object(let o) = document { body = o } else { body = [] }

        var language = fallbackLanguage
        if case .object(let r) = member(body, "result"), case .string(let s) = member(r, "language"), !s.isEmpty {
            language = s
        }

        let entries: [PyJSONValue]
        if case .array(let items) = member(body, "transcription") { entries = items } else { entries = [] }
        var segments: [TranscriptSegment] = []
        for entry in entries {
            // 壊れた要素はその要素だけ飛ばす（1 区間の不良で Part 全体を失わない）。
            guard case .object(let e) = entry, case .object(let offsets) = member(e, "offsets"),
                case .string(let text) = member(e, "text")
            else { continue }
            guard let start = seconds(member(offsets, "from")), let end = seconds(member(offsets, "to")) else {
                continue
            }
            let t = PyText.strip(text)
            if t.isEmpty { continue }
            segments.append(TranscriptSegment(start: start, end: end, text: t))
        }
        let text = PyText.strip(segments.map(\.text).joined())
        return (language, text, segments)
    }

    /// キーはスカラー列で比べる（重複キーは `decode` が後勝ちで 1 つにしている）。
    static func member(_ o: [(String, PyJSONValue)], _ key: String) -> PyJSONValue? {
        o.first { PyText.scalarsEqual($0.0, key) }?.1
    }

    /// ASR-05: offsets はミリ秒。整数でも小数でも受け、文字列・bool・null は nil。
    /// F-71: 秒にして読めない値（NaN・±Infinity・絶対値が 10 億秒超）も nil（その要素だけ飛ばす。§8.4 の読み戻しと同じ条件）。
    static func seconds(_ v: PyJSONValue?) -> Double? {
        let ms: Double
        switch v {
        case .int(let n)?: ms = Double(n)
        case .double(let d)?: ms = d
        default: return nil
        }
        let s = PyRound.round(ms / 1000.0, digits: 3)
        return SecondsToMillis.isReadable(s) ? s : nil
    }
}
