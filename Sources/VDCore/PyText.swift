// Python 3.12 の str の振る舞い（strip・splitlines・\s・casefold）を Unicode スカラー単位で写す（PLAN §5.7、CR-24）。
import Foundation

/// Python 互換の文字列処理。golden（voicedock の Python 3.12 / unicodedata 15.0.0）とバイト単位で一致させる。
///
/// **`Character`（書記素）ではなく `Unicode.Scalar` で処理する。**Python の `str` はコードポイントの列であり、
/// `"\r\n"` や結合文字を 1 文字として扱う Swift の `Character` とは数え方が違う。
public enum PyText {
    /// `str.isspace()`（= `re` の `\s`）の対象。golden `pytext/enumerations.json` の `isspace` と一致する（29 個）。
    /// `CharacterSet.whitespacesAndNewlines` とは U+001C–U+001F の有無が違うので使わない。
    static let spaceScalars: Set<UInt32> = [
        0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x001C, 0x001D, 0x001E, 0x001F, 0x0020, 0x0085, 0x00A0, 0x1680,
        0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
        0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
    ]

    /// `str.splitlines()` の区切り（10 個）。`\r\n` は 2 つで 1 つの区切りとして扱う（`splitLines` の中で）。
    static let lineBreakScalars: Set<UInt32> = [
        0x000A, 0x000B, 0x000C, 0x000D, 0x001C, 0x001D, 0x001E, 0x0085, 0x2028, 0x2029,
    ]

    /// Python の `str.isspace()`（1 文字）。
    public static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        spaceScalars.contains(scalar.value)
    }

    /// Python の `str.strip()`（引数なし）。前後の `isSpace` を除く。
    public static func strip(_ text: String) -> String {
        strip(text, where: isSpace)
    }

    /// Python の `str.strip(chars)`。前後の `chars` に含まれるスカラーを除く。
    public static func strip(_ text: String, chars: Set<Unicode.Scalar>) -> String {
        strip(text) { chars.contains($0) }
    }

    /// Python の `str.splitlines()`（`keepends=False`）。末尾の区切りの後に空要素を作らない。空文字列は空配列。
    public static func splitLines(_ text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if lineBreakScalars.contains(scalar.value) {
                lines.append(String(current))
                current = String.UnicodeScalarView()
                if scalar.value == 0x000D, index + 1 < scalars.count, scalars[index + 1].value == 0x000A {
                    index += 1
                }
            } else {
                current.append(scalar)
            }
            index += 1
        }
        if !current.isEmpty {
            lines.append(String(current))
        }
        return lines
    }

    /// Python の `re.sub(r"\s+", " ", text)`。`isSpace` の連続を U+0020 1 つに置き換える（前後は削らない）。
    public static func collapseWhitespace(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var inRun = false
        for scalar in text.unicodeScalars {
            if isSpace(scalar) {
                if !inRun {
                    result.append(" ")
                    inRun = true
                }
            } else {
                result.append(scalar)
                inRun = false
            }
        }
        return String(result)
    }

    /// Python の `str.casefold()`（Unicode 15.0.0 の CaseFolding.txt の C + F）。語末シグマの規則は無い。
    /// `lowercased()` は使わない（`ß` が `ss` にならず、`ΣΑΣ` が `σας` になる）。
    public static func casefold(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if let mapped = PyCaseFoldTable.map[scalar.value] {
                for value in mapped {
                    if let folded = Unicode.Scalar(value) {
                        result.append(folded)
                    }
                }
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// Python の `unicodedata.combining(c) != 0`（正準結合クラスが 0 でない）。
    public static func isCombining(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.canonicalCombiningClass != .notReordered
    }

    /// Python の `unicodedata.normalize("NFC", text)`。
    public static func nfc(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }

    /// Python の `unicodedata.normalize("NFKC", text)`。
    public static func nfkc(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
    }

    /// 2 つの文字列が Unicode スカラー列として等しいか。
    /// **Swift の `==` は正準等価で比べる**（`"か\u{3099}" == "が"` が真）ので、正規化の有無を確かめるときはこれを使う。
    public static func scalarsEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
    }

    static func strip(_ text: String, where predicate: (Unicode.Scalar) -> Bool) -> String {
        let scalars = Array(text.unicodeScalars)
        var start = 0
        var end = scalars.count
        while start < end, predicate(scalars[start]) {
            start += 1
        }
        while end > start, predicate(scalars[end - 1]) {
            end -= 1
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[start..<end])
        return String(view)
    }
}
