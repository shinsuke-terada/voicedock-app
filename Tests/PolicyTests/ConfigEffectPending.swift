// まだ ConfigEffect（CE）のテストが無い設定キーと、書く予定のチケット（PLAN §6.2・CR-14。T-09）。
// テストを書いたチケットは、自分の PR でここから自分のキーを消す。

/// まだ ConfigEffect のテストが無いキー → 書く予定のチケット。空になったら網羅完了（T-43 の受け入れ条件）。
enum ConfigEffectPending {
    static let owners: [String: String] = [
        "timeZone": "T-22",
        "session.blockGapSeconds": "T-22",
        "session.idleCloseSeconds": "T-22",
        "session.allowReopen": "T-22",
        "session.maxParts": "T-22",
        "session.maxDurationSeconds": "T-22",
        "llm.modelID": "T-22",
        "device.mountMode": "T-15",
        "device.scanIntervalSeconds": "T-15",
        "device.snapshotMaxAgeSeconds": "T-38",
        "cleanup.deleteSourceAudio": "T-38",
        "cleanup.deleteEvaluationBackoffSeconds": "T-38",
        "cleanup.deleteResultTimeoutSeconds": "T-38",
        "audio.inboxRetain": "T-18",
        "cleanup.deleteNormalizedAfterTranscribe": "T-18",
        "retry.maxAttempts": "T-18",
        "retry.backoffSeconds": "T-18",
        "obsidian.wiki.vaultIndexCacheSeconds": "T-29",
        "obsidian.raw.folderTemplate": "T-33",
        "cleanup.deleteSkippedSource": "T-39",
    ]
}
