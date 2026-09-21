// Daily ノートの警告行（PLAN §8.6 / NOTE-05。voicedock daily.py:300-340）。欠落を隠さない。SKIPPED に「再試行されます」と書かない。
import Foundation
import VDCore

public enum DailyWarnings {
    /// FAILED の行。`%ld` に本数が入る（`⚠` は U+26A0、その後に半角空白）
    public static let failedLineTemplate = "> ⚠ この日の録音のうち %ld 本が処理できませんでした。次にデバイスを接続したときに自動で再試行されます。"
    public static let retryAction = "デバイスから採り直してください。"

    static let actionableMark = "⚠ "
    /// 理由の区切り（U+30FB）
    static let reasonSeparator = "・"
    static let unknownReasonName = "理由不明"

    /// 除外理由の表示名。表に無いコードはコード名のまま出す（PT-06: コード名の文字列は ErrorCode.swift だけ）
    static let displayNames: [ErrorCode: String] = [
        .duplicateContent: "重複",
        .sourceMissing: "元ファイルが見つかりません",
        .normalizedMissing: "元ファイルが見つかりません",
        .noSpeechDetected: "無音",
    ]

    /// 見出しの直後に入れる行（最大 2 行。FAILED が先）。
    public static func lines(failed: [ExcludedPart], skipped: [ExcludedPart]) -> [String] {
        var out: [String] = []
        if !failed.isEmpty {
            out.append(String(format: failedLineTemplate, failed.count))
        }
        if !skipped.isEmpty {
            // 許可リストで判定する。未知のコード・理由なしは操作が要る側
            let actionable = skipped.contains { part in
                guard let code = part.errorCode else { return true }
                return !SkipReasons.benign.contains(code)
            }
            let mark = actionable ? actionableMark : ""
            let action = actionable ? retryAction : ""
            let reasons = orderedReasonKeys(uniqueKeys(skipped.map(\.reasonKey)))
                .map { displayName(reasonKey: $0) }
                .joined(separator: reasonSeparator)
            out.append(
                "> " + mark + "この日の録音のうち \(skipped.count) 本を除外しました（" + reasons + "）。自動では再試行されません。"
                    + action)
        }
        return out
    }

    public static func displayName(_ code: ErrorCode?) -> String {
        displayName(reasonKey: code?.rawValue ?? "")
    }

    /// 理由の鍵（ExcludedPart.reasonKey）から表示名へ
    static func displayName(reasonKey: String) -> String {
        if let code = ErrorCode(rawValue: reasonKey), let name = displayNames[code] {
            return name
        }
        return reasonKey.unicodeScalars.isEmpty ? unknownReasonName : reasonKey
    }

    /// 鍵の重複をスカラー列で除く（出現順。Swift の String の == は正準等価で比べ、Python の set[str] と違う）
    static func uniqueKeys(_ keys: [String]) -> [String] {
        var seen = Set<[UInt32]>()
        var unique: [String] = []
        for key in keys where seen.insert(key.unicodeScalars.map(\.value)).inserted {
            unique.append(key)
        }
        return unique
    }

    /// 重複の無い理由の鍵を並べる（宣言順、同順位は鍵のスカラー値の辞書順）
    static func orderedReasonKeys(_ keys: [String]) -> [String] {
        func rank(_ key: String) -> Int {
            ErrorCode(rawValue: key)?.declarationIndex ?? Int.max
        }
        return keys.sorted { lhs, rhs in
            let a = rank(lhs)
            let b = rank(rhs)
            if a != b { return a < b }
            return lhs.unicodeScalars.map(\.value).lexicographicallyPrecedes(rhs.unicodeScalars.map(\.value))
        }
    }
}
