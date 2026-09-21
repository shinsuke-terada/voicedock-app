// Python の round(x, n)（浮動小数を小数 n 桁へ）と同じ丸め（PLAN §5.7、CR-24）。
import Foundation

/// Python の `round(x, digits)`。
///
/// Python は x の**正確な 2 進値**を 10 進で小数 `digits` 桁へ丸め（ちょうど半分なら偶数側）、それを浮動小数に戻す。
/// C の `%.nf` も正確な 2 進値を最近接偶数で丸めるので、その文字列を `Double` に戻せば同じ値になる
/// （`(x * 1000).rounded() / 1000` は掛け算の誤差で結果が変わりうるので使わない）。
public enum PyRound {
    public static func round(_ value: Double, digits: Int) -> Double {
        guard value.isFinite, digits >= 0 else {
            return value
        }
        let text = String(format: "%.\(digits)f", value)
        return Double(text) ?? value
    }
}
