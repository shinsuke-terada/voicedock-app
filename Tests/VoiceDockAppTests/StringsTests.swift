// Strings（パネルの文言）が T-30 §4.12 の表と逐語で一致することのテスト。
import Testing
import VDPipeline

@testable import VoiceDockApp

@Suite("Strings")
struct StringsTests {
    /// (名前, 実装の値, §4.12 の表の値)
    static let table: [(String, String, String)] = [
        ("ok", Strings.ok, "OK"),
        ("unknownDevice", Strings.unknownDevice, "デバイス"),
        ("unknownTime", Strings.unknownTime, "時刻不明"),
        ("bootFailureTitle", Strings.bootFailureTitle, "VoiceDock を起動できませんでした"),
        ("bootFailureDirectories", Strings.bootFailureDirectories("E"), "作業フォルダを作れません: E"),
        ("bootFailureCatalog", Strings.bootFailureCatalog("E"), "モデルの一覧を読めません: E"),
        ("bootFailureDatabase", Strings.bootFailureDatabase("E"), "データベースを開けません: E"),
        ("statusIdle", Strings.statusIdle, "待機中"),
        ("statusScanning", Strings.statusScanning, "デバイスを調べています"),
        (
            "statusIngesting", Strings.statusIngesting(device: "D", copied: 1, total: 2),
            "D から取り込み中 1/2 — コピーが終われば抜いて大丈夫です"
        ),
        ("statusNormalizing", Strings.statusNormalizing("07:12"), "変換中 07:12 の録音"),
        ("statusTranscribing", Strings.statusTranscribing("07:12"), "文字起こし中 07:12 の録音"),
        ("statusWritingRawNote", Strings.statusWritingRawNote, "Raw ノートを書いています"),
        ("statusMerging", Strings.statusMerging, "文字起こしをまとめています"),
        ("statusAnalyzing", Strings.statusAnalyzing("2026-08-29"), "要約中 2026-08-29"),
        ("statusWritingDailyNote", Strings.statusWritingDailyNote("2026-08-29"), "ノートを書いています 2026-08-29"),
        ("statusConfigInvalid", Strings.statusConfigInvalid, "設定にエラーがあります"),
        ("statusPaused", Strings.statusPaused([.license, .whisperMissing]), "停止中: whisper-cli がありません、ライセンス"),
        ("connectedNow", Strings.connectedNow("A、B"), "接続中（A、B）"),
        ("neverConnected", Strings.neverConnected, "まだありません"),
        ("labelLastConnected", Strings.labelLastConnected, "最終接続"),
        ("labelBacklog", Strings.labelBacklog, "未処理"),
        ("labelDeviceFree", Strings.labelDeviceFree, "デバイスの空き容量"),
        ("sectionStatus", Strings.sectionStatus, "状態"),
        ("sectionAttention", Strings.sectionAttention, "要対応"),
        ("sectionOnboarding", Strings.sectionOnboarding, "はじめに"),
        ("sectionVault", Strings.sectionVault, "保存先（Vault）"),
        ("sectionModels", Strings.sectionModels, "モデル"),
        ("sectionGeneral", Strings.sectionGeneral, "一般"),
        ("sectionDeletion", Strings.sectionDeletion, "元音声の削除"),
        ("sectionDetails", Strings.sectionDetails, "詳細"),
        ("buttonRetry", Strings.buttonRetry, "再試行"),
        ("buttonReloadConfig", Strings.buttonReloadConfig, "設定を読み直す"),
        ("buttonRevealConfig", Strings.buttonRevealConfig, "設定ファイルを Finder で表示"),
        ("buttonRevealLogs", Strings.buttonRevealLogs, "ログを Finder で表示"),
        ("buttonQuit", Strings.buttonQuit, "VoiceDock を終了"),
        ("reloadOK", Strings.reloadOK, "設定を読み直しました"),
        ("reloadInvalid", Strings.reloadInvalid(2), "設定にエラーがあります（2 件）"),
        ("versionLine", Strings.versionLine("0.1.0"), "版 0.1.0"),
        ("iconDescription.idle", Strings.iconDescription(.idle), "待機中"),
        ("iconDescription.ingesting", Strings.iconDescription(.ingesting), "取り込み中"),
        ("iconDescription.processing", Strings.iconDescription(.processing), "処理中"),
        ("iconDescription.attention", Strings.iconDescription(.attention), "要対応"),
        ("iconTrashDescription", Strings.iconTrashDescription, "元音声の削除が有効です"),
        // F-65: 長押しの有効化とカード型のパネル（T-30 §4.12 の F-65 の表）
        ("holdSeconds", Strings.holdSeconds, "3"),
        ("holdToEnableHint", Strings.holdToEnableHint, "赤いボタンを 3 秒長押しすると有効になります。途中で離すと取り消します"),
        ("holdKeepPressing", Strings.holdKeepPressing, "そのまま押し続けてください…"),
        ("deletionUnavailable", Strings.deletionUnavailable, "設定を読み込めていないため、いまは操作できません"),
        ("buttonBack", Strings.buttonBack, "戻る"),
        ("screenSettings", Strings.screenSettings, "設定"),
        ("rowDeletion", Strings.rowDeletion, "元音声の削除"),
        ("rowDetails", Strings.rowDetails, "詳細・診断"),
        ("sectionDiagnostics", Strings.sectionDiagnostics, "診断"),
        ("sectionBacklog", Strings.sectionBacklog, "後追い"),
        ("deletionOn", Strings.deletionOn, "有効"),
        ("deletionOff", Strings.deletionOff, "無効"),
        ("attentionMore", Strings.attentionMore(3), "ほか 3 件"),
        ("onboardingProgress", Strings.onboardingProgress(done: 2, total: 4), "2/4"),
        ("statusDetailLine", Strings.statusDetailLine(lastConnected: "A", backlog: "B"), "最終接続 A · B"),
        ("deviceFreeLine", Strings.deviceFreeLine("DJIMIC3 4.2 GiB"), "デバイスの空き容量 DJIMIC3 4.2 GiB"),
        // F-66: 今すぐ要約（T-30 §4.12 の F-66 の表）
        ("buttonSummarizeNow", Strings.buttonSummarizeNow, "今すぐ要約"),
        ("summarizeNowStarted", Strings.summarizeNowStarted(3), "要約を始めました（3 件）"),
        ("summarizeNowStarted.1", Strings.summarizeNowStarted(1), "要約を始めました（1 件）"),
        ("summarizeNowNothing", Strings.summarizeNowNothing, "新しく要約する録音はありません"),
    ]

    @Test("文言は §4.12 の表と逐語で一致する", arguments: table.map(\.0))
    func matchesTable(name: String) throws {
        let row = try #require(Self.table.first { $0.0 == name })
        #expect(row.1 == row.2)
    }

    @Test("停止中の理由が空なら『停止中: 』だけ")
    func pausedWithNoReasons() {
        #expect(Strings.statusPaused([]) == "停止中: ")
    }
}
