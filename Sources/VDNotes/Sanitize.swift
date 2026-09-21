// ファイル名の sanitize（PLAN §8.6 の SN-1〜SN-9。voicedock notes.py:42-105 と同じ順）。ファイル名にだけ適用する。
import VDCore

public enum Sanitize {
    /// SN-8 の代替名
    public static let fallbackName = "Untitled"

    /// SN-9 の予約名（大文字）。22 個
    public static let reservedNames: Set<String> = Set(
        ["CON", "PRN", "AUX", "NUL"] + (1...9).map { "COM\($0)" } + (1...9).map { "LPT\($0)" })

    /// SN-2 で取り除く制御文字（U+0000〜U+001F と U+007F。C1 は含まない）。frontmatter の quote も同じ集合を使う。
    static let controlScalars: Set<Unicode.Scalar> = Set(
        (0x00...0x1F).compactMap { Unicode.Scalar(UInt32($0)) } + [Unicode.Scalar(0x7F)])

    /// SN-3 で `-` に置き換えるスカラー（パス区切りと Windows で使えない文字）
    static let replacedScalars: [Unicode.Scalar: Unicode.Scalar] = [
        "/": "-", "\\": "-", ":": "-", "*": "-", "?": "-", "\"": "-", "<": "-", ">": "-", "|": "-",
    ]

    /// SN-4 で取り除くスカラー（Obsidian のリンク・ブロック参照の記法）
    static let removedScalars: Set<Unicode.Scalar> = ["#", "^", "[", "]"]

    public static func fileName(_ name: String, maxBytes: Int) -> String {
        var s = PyText.nfc(name)  // SN-1
        s = ScalarText.removing(s, controlScalars)  // SN-2
        s = ScalarText.replacing(s, replacedScalars)  // SN-3
        s = ScalarText.removing(s, removedScalars)  // SN-4
        s = PyText.strip(PyText.collapseWhitespace(s))  // SN-5
        s = PyText.strip(s, chars: ["."])  // SN-6
        s = truncate(s, maxBytes: maxBytes)  // SN-7
        if s.unicodeScalars.isEmpty {  // SN-8
            s = fallbackName
        }
        if reservedNames.contains(s.uppercased()) {  // SN-9
            s += "_"
        }
        return s
    }

    /// SN-7: UTF-8 のバイト数が maxBytes を超える間、末尾のスカラーを削る。その後、削ったかどうかにかかわらず末尾の結合文字を削る。
    static func truncate(_ s: String, maxBytes: Int) -> String {
        var scalars = Array(s.unicodeScalars)
        while !scalars.isEmpty && utf8Bytes(scalars) > maxBytes {
            scalars.removeLast()
        }
        while let last = scalars.last, PyText.isCombining(last) {
            scalars.removeLast()
        }
        return ScalarText.string(scalars)
    }

    /// 各スカラーの UTF-8 長の合計
    static func utf8Bytes(_ scalars: [Unicode.Scalar]) -> Int {
        scalars.reduce(0) { total, scalar in
            let value = scalar.value
            if value < 0x80 { return total + 1 }
            if value < 0x800 { return total + 2 }
            if value < 0x10000 { return total + 3 }
            return total + 4
        }
    }
}
