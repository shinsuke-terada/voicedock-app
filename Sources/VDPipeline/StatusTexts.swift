// 状態の表示に使う整形（PLAN §8.12。voicedock status.py:96-134, 175-194）。
// パネルの上端（VoiceDockApp）と「状態の詳細」（StatusReporter。T-32）が同じ関数を使う。
import Foundation

/// 状態の表示に使う整形（PLAN §8.12）。
public enum StatusTexts {
    public static let gibBytes: Double = 1024 * 1024 * 1024

    /// 「<x.x> GiB」（小数 1 桁。負の値は 0 として扱う）
    public static func gib(_ bytes: Int64) -> String {
        String(format: "%.1f GiB", max(0, Double(bytes)) / gibBytes)
    }

    /// PLAN §8.12「未処理 <h 小数 1 桁> 時間ぶん（<n> 件）」／「、うち <k> 件は長さ不明」／「未処理なし」
    public static func backlogLine(count: Int, seconds: Double, unknownDuration: Int) -> String {
        if count == 0 { return "未処理なし" }
        var t = "未処理 " + String(format: "%.1f", max(0, seconds) / 3600) + " 時間ぶん（" + String(count) + " 件）"
        if unknownDuration > 0 {
            t += "、うち " + String(unknownDuration) + " 件は長さ不明"
        }
        return t
    }

    /// ガードの理由の日本語（PLAN §5.4）。パネルの 1 行（T-30）・要対応（T-32）・DR-09（T-32）が共有する
    public static func pauseWord(_ r: PauseReason) -> String {
        switch r {
        case .diskSpaceLow: "空き容量不足"
        case .whisperMissing: "whisper-cli がありません"
        case .modelMissing: "Whisper モデルがありません"
        case .vadModelMissing: "VAD モデルがありません"
        case .vaultNotConfigured: "Vault が未設定"
        case .vaultUnavailable: "Vault が使えません"
        case .llmNotSelected: "LLM が未選択"
        case .llmModelMissing: "LLM モデルがありません"
        case .llmInsufficientMemory: "メモリ不足"
        case .llamaServerMissing: "llama-server がありません"
        case .license: "ライセンス"
        }
    }
}
