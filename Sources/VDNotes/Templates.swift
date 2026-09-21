// フォルダ名・ファイル名のテンプレート（PLAN §8.6。voicedock raw.py:97-116）。
import Foundation
import VDCore

public enum NoteTemplate {
    /// `{yyyymmdd}` → `20260829`、`{date}` → `2026-08-29`、`{time}` → `000000` の順に置換する。それ以外の `{…}` は残す（CV-13）。
    /// 置換は `.literal`（スカラー単位。既定の比較は結合文字が続くプレースホルダを見逃す。PLAN §5.7）。
    public static func render(_ template: String, day: LocalDate) -> String {
        template
            .replacingOccurrences(of: "{yyyymmdd}", with: day.stamp, options: .literal)
            .replacingOccurrences(of: "{date}", with: day.dashed, options: .literal)
            .replacingOccurrences(of: "{time}", with: "000000", options: .literal)
    }
}
