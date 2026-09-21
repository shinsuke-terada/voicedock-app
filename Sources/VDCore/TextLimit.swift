// 文字数の規則（CR-23）: Unicode スカラー数で数え、スカラー単位で切る。
import Foundation

/// 文字数の規則（CR-23）: Unicode スカラー数で数え、スカラー単位で切る（Python の len と同じ）。
public enum TextLimit {
    public static func scalarCount(_ s: String) -> Int { s.unicodeScalars.count }

    /// 先頭 n スカラー。
    public static func prefix(_ s: String, scalars n: Int) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: s.unicodeScalars.prefix(max(0, n)))
        return String(view)
    }

    /// 200 スカラー以下はそのまま、超えたら先頭 199 スカラー + "…"（U+2026）。error_message・events.detail に使う（PLAN §5.2）。
    public static func truncate200(_ s: String) -> String {
        guard scalarCount(s) > 200 else { return s }
        return prefix(s, scalars: 199) + "\u{2026}"
    }
}
