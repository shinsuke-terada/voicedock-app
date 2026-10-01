// アプリと reaper の版。VERSION ファイルと一致させる（PLAN §11.4）。
import Foundation

public enum AppVersion {
    /// VERSION ファイルの中身（前後の空白・改行を除いたもの）と同じ文字列。版を上げる PR で両方を変える。
    public static let string = "1.0.0"

    /// "X.Y.Z"（各要素は ASCII の 10 進。符号・空要素・余計な要素は不可）を数値の組にする。形式外は nil。
    public static func components(_ s: String) -> (major: Int, minor: Int, patch: Int)? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.unicodeScalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }) else {
                return nil
            }
            guard let n = Int(part) else { return nil }
            numbers.append(n)
        }
        return (numbers[0], numbers[1], numbers[2])
    }

    /// 両方が components で読め、3 つの数が等しいときだけ真。文字列の辞書順で比べない（"1.10.0" と "1.9.0"）。
    public static func isSame(_ a: String, _ b: String) -> Bool {
        guard let x = components(a), let y = components(b) else { return false }
        return x.major == y.major && x.minor == y.minor && x.patch == y.patch
    }
}
