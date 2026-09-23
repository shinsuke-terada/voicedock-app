// whisper.cpp v1.9.4 の -oj の生 JSON を読む（PLAN §8.4 手順 7。voicedock transcribe.py:333-389）。
import Foundation
import VDCore

public enum WhisperOutputParser {
    /// JSON として読めない（またはトップレベルが null）なら nil。それ以外は壊れた要素を飛ばして必ず結果を返す。
    /// 読む前に `lenient` で手前処理をする（whisper の生 JSON に限る寛容な読み方。F-82・X-41）。
    public static func parse(
        _ data: Data, fallbackLanguage: String
    ) -> (language: String, text: String, segments: [TranscriptSegment])? {
        parseReportingRepair(data, fallbackLanguage: fallbackLanguage).map { ($0.language, $0.text, $0.segments) }
    }

    /// parse と同じ結果に、手前処理が入力を直した（不正な UTF-8 を置き換えた・生の制御文字をエスケープした）かを添える。
    /// 直した transcript の文字数が minChars に届かなくても無音にしない（Transcriber。F-82・X-41）ために使う
    static func parseReportingRepair(
        _ data: Data, fallbackLanguage: String
    ) -> (language: String, text: String, segments: [TranscriptSegment], repaired: Bool)? {
        let prepared = lenient(data)
        guard let document = PyJSON.decode(prepared.text), document != .null else { return nil }
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
        return (language, text, segments, prepared.repaired)
    }

    /// whisper.cpp の `-oj` は文字列の中の `"` と `\` しかエスケープしないので、区間の境目で割れた多バイト文字（不正な UTF-8）や
    /// 生の制御文字（U+0000〜U+001F）が 1 つあるだけで全体が読めず、Part が毎回失敗する（voicedock も同じ。X-41）。F-82 の手前処理:
    /// (a) 不正な UTF-8 は U+FFFD に置き換える、(b) 文字列の中の生の制御文字だけを `\u00XX`（小文字の 16 進）にする。
    /// 文字列の外と、`\` の直後の 1 文字（エスケープの続き）は触らない。正常な JSON は 1 バイトも変えない。
    /// 引用符・逆斜線・制御文字はどれも ASCII なので、UTF-8 のバイト列のまま判定してよい（多バイト文字のバイトは 0x80 以上）。
    static func lenientText(_ data: Data) -> String { lenient(data).text }

    /// lenientText の本体。`repaired` は入力を 1 バイトでも変えたか（不正な UTF-8 の置き換え・制御文字のエスケープ）
    static func lenient(_ data: Data) -> (text: String, repaired: Bool) {
        let text = String(decoding: data, as: UTF8.self)
        var repaired = !text.utf8.elementsEqual(data)
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count)
        var inString = false
        var escaping = false
        for byte in text.utf8 {
            if inString {
                if escaping {
                    escaping = false
                } else if byte == backslash {
                    escaping = true
                } else if byte == quote {
                    inString = false
                } else if byte < firstNonControl {
                    out.append(contentsOf: [backslash, lowerU, zero, zero])
                    out.append(contentsOf: [hexDigits[Int(byte >> 4)], hexDigits[Int(byte & 0x0F)]])
                    repaired = true
                    continue
                }
            } else if byte == quote {
                inString = true
            }
            out.append(byte)
        }
        return (String(decoding: out, as: UTF8.self), repaired)
    }

    static let quote = UInt8(ascii: "\"")
    static let backslash = UInt8(ascii: "\\")
    static let lowerU = UInt8(ascii: "u")
    static let zero = UInt8(ascii: "0")
    /// JSON が文字列の中にそのまま書くことを許さない最後の文字（U+001F）の次
    static let firstNonControl: UInt8 = 0x20
    static let hexDigits = Array("0123456789abcdef".utf8)

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
