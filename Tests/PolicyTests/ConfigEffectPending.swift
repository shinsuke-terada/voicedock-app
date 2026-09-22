// まだ ConfigEffect（CE）のテストが無い設定キーと、書く予定のチケット（PLAN §6.2・CR-14。T-09）。
// テストを書いたチケットは、自分の PR でここから自分のキーを消す。

/// まだ ConfigEffect のテストが無いキー → 書く予定のチケット。空になったら網羅完了（T-43 の受け入れ条件）。
enum ConfigEffectPending {
    static let owners: [String: String] = [
        "device.snapshotMaxAgeSeconds": "T-38",
        "cleanup.deleteSourceAudio": "T-38",
        "cleanup.deleteEvaluationBackoffSeconds": "T-38",
        "cleanup.deleteResultTimeoutSeconds": "T-38",
        "cleanup.deleteSkippedSource": "T-39",
    ]
}
