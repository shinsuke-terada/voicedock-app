// パネルの文言（日本語のみ。PLAN §8.12「文言は Strings.swift に集める」）。
// 後続のチケット（T-31 / T-32 / T-40 / T-41）はこのファイルに自分の節の文言を足す。
import VDPipeline

/// パネルの文言（T-30 §4.12 の表の逐語）。
enum Strings {
    static let ok = "OK"
    static let unknownDevice = "デバイス"
    static let unknownTime = "時刻不明"

    // 起動の失敗
    static let bootFailureTitle = "VoiceDock を起動できませんでした"
    static func bootFailureDirectories(_ e: String) -> String { "作業フォルダを作れません: " + e }
    static func bootFailureCatalog(_ e: String) -> String { "モデルの一覧を読めません: " + e }
    static func bootFailureDatabase(_ e: String) -> String { "データベースを開けません: " + e }

    // 状態の 1 行
    static let statusIdle = "待機中"
    static let statusScanning = "デバイスを調べています"
    static func statusIngesting(device: String, copied: Int, total: Int) -> String {
        device + " から取り込み中 " + String(copied) + "/" + String(total) + " — コピーが終われば抜いて大丈夫です"
    }
    static func statusNormalizing(_ hhmm: String) -> String { "変換中 " + hhmm + " の録音" }
    static func statusTranscribing(_ hhmm: String) -> String { "文字起こし中 " + hhmm + " の録音" }
    static let statusWritingRawNote = "Raw ノートを書いています"
    static let statusMerging = "文字起こしをまとめています"
    static func statusAnalyzing(_ day: String) -> String { "要約中 " + day }
    static func statusWritingDailyNote(_ day: String) -> String { "ノートを書いています " + day }
    static let statusConfigInvalid = "設定にエラーがあります"
    /// PauseReason.allCases の順に並べる（渡された順ではない）
    static func statusPaused(_ reasons: [PauseReason]) -> String {
        "停止中: " + PauseReason.allCases.filter { reasons.contains($0) }.map(StatusTexts.pauseWord).joined(separator: "、")
    }

    // 状態の節の行
    static func connectedNow(_ names: String) -> String { "接続中（" + names + "）" }
    static let neverConnected = "まだありません"
    static let labelLastConnected = "最終接続"
    static let labelBacklog = "未処理"
    static let labelDeviceFree = "デバイスの空き容量"

    // 節の見出し（PLAN §8.12 の 1〜8）
    static let sectionStatus = "状態"
    static let sectionAttention = "要対応"
    static let sectionOnboarding = "はじめに"
    static let sectionVault = "保存先（Vault）"
    static let sectionModels = "モデル"
    static let sectionGeneral = "一般"
    static let sectionDeletion = "元音声の削除"
    static let sectionDetails = "詳細"

    // ボタン
    static let buttonRetry = "再試行"
    static let buttonReloadConfig = "設定を読み直す"
    static let buttonRevealConfig = "設定ファイルを Finder で表示"
    static let buttonRevealLogs = "ログを Finder で表示"
    static let buttonQuit = "VoiceDock を終了"

    // 読み直しの結果
    static let reloadOK = "設定を読み直しました"
    static func reloadInvalid(_ count: Int) -> String { "設定にエラーがあります（" + String(count) + " 件）" }

    static func versionLine(_ version: String) -> String { "版 " + version }

    // アイコン
    static func iconDescription(_ state: IconState) -> String {
        switch state {
        case .idle: "待機中"
        case .ingesting: "取り込み中"
        case .processing: "処理中"
        case .attention: "要対応"
        }
    }
    static let iconTrashDescription = "元音声の削除が有効です"
}
