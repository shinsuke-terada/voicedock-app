// パネルの文言（日本語のみ。PLAN §8.12「文言は Strings.swift に集める」）。
// 後続のチケット（T-31 / T-32 / T-40 / T-41）はこのファイルに自分の節の文言を足す。
import VDCore
import VDModels
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

    // T-31: はじめに（PLAN §8.12 の 3）
    static let onboardingVault = "Vault を選ぶ"
    static let onboardingWhisper = "Whisper モデルを入手する"
    static let onboardingLLM = "LLM を選んで入手する"
    static let onboardingLoginItem = "ログイン時に起動する"
    static let onboardingDeviceName = "デバイスの名前を変える"
    static let onboardingLater = "今はしない"
    /// アプリは改名しない（DEV-10）。手順を見せるだけ
    static func renameInstructions(_ names: [String]) -> String {
        names.joined(separator: "、")
            + " という名前のデバイスがつながっています。VoiceDock はデバイスに一切書き込みません。次の手順で利用者が名前を変えてください。\n"
            + "1. Finder のサイドバーでデバイスを選び、名前をゆっくり 2 回クリックして「DJIMIC3」などに変えます\n"
            + "2. 変えたらデバイスを取り外して、もう一度つなぎ直してください"
    }

    // T-31: 保存先（Vault）（PLAN §8.12 の 4）
    static let chooseVaultMessage = "Obsidian の Vault のフォルダ（.obsidian があるフォルダ）を選んでください"
    static let chooseVaultPrompt = "この Vault を使う"
    static let buttonChangeVault = "変更…"
    static let vaultNotChosen = "まだ選ばれていません"

    // T-31: モデル（PLAN §8.12 の 5）
    static let chooseGGUFMessage = "読み込む .gguf ファイルを選んでください"
    static let chooseGGUFPrompt = "読み込む"
    static let buttonImportGGUF = "ファイルから読み込む…"
    static let buttonFetchModel = "入手する"
    static let buttonCancelDownload = "やめる"
    static let modelPresent = "入手済み"
    static let modelAbsent = "未入手"
    /// total が 0 以下（全体が不明）なら受け取った量だけ
    static func modelProgress(received: Int64, total: Int64) -> String {
        guard total > 0 else { return StatusTexts.gib(received) }
        return StatusTexts.gib(received) + " / " + StatusTexts.gib(total)
    }
    static let labelWhisperModel = "Whisper モデル"
    static let labelVADModel = "VAD モデル"
    static let labelLLMModel = "LLM モデル"
    static let vadDisabled = "VAD は無効です（無音から幻覚が生成され、13 倍以上遅くなります）"
    static let llmNotSelected = "選ばれていません"
    static func notEnoughMemory(required: Int, actual: Int) -> String {
        "メモリが足りません（" + String(required) + " GB 以上が必要。この Mac は " + String(actual) + " GB）"
    }
    static func customModelName(_ shortSHA: String) -> String { "読み込んだモデル（" + shortSHA + "）" }
    static let customModelUnsupported = "動作保証外のモデルです"

    // T-31: 一般（PLAN §8.12 の 6）
    static let labelLoginItem = "ログイン時に起動"
    static let buttonOpenLoginItemSettings = "システム設定を開く"
    static let loginItemRequiresApproval = "システム設定で許可が要ります"
    static let loginItemNotFound = "アプリの場所が不明です（/Applications に置いてから試してください）"
    static let uiStateSaveFailed = "選択を記録できませんでした（<HOME>/ui-state.json に書けません）"
    static func configRejected(_ violations: [ConfigViolation]) -> String {
        "設定に書けませんでした: " + violations.map(\.rendered).joined(separator: "、")
    }

    // T-40: 元音声の削除（PLAN §8.9.8・§8.12 の 7）。事前確認・確認語・挿し直しの案内は DeletionStrings
    static let buttonEnableDeletion = "有効にする"
    static let buttonEnableSkippedDeletion = "無音・重複も消す"
    static let buttonDisableDeletion = "無効にする"
    static func disableFailed(_ stages: [String]) -> String {
        "無効にできなかった段: " + stages.joined(separator: ", ")
    }
    /// 有効化・根拠 B の失敗（T-40 §4.5 の表）
    static func enableFailed(_ e: EnableError) -> String {
        "有効にできませんでした: " + enableFailureReason(e)
    }
    static func enableFailureReason(_ e: EnableError) -> String {
        switch e {
        case .notConfirmed: "赤いボタンを " + holdSeconds + " 秒長押ししてください"
        case .install(let m): "削除モジュールを置けません（" + m + "）"
        case .signature: "削除モジュールの署名を確かめられません"
        case .reaperConfWrite(let m): "reaper.conf を書けません（" + m + "）"
        case .config(let v) where v.isEmpty: "元音声の削除が有効になっていません"
        case .config(let v): "設定に書けません（" + v.map(\.rendered).joined(separator: "、") + "）"
        case .configNotLoaded: "設定が読み込まれていません"
        case .rollback(let stages): "元に戻せなかった段があります（" + stages.joined(separator: ", ") + "）"
        }
    }

    // F-65: 長押しの有効化（PLAN §8.9.8 の 2）。秒数は HoldToConfirmButton.holdDuration から作る（CR-06）
    static let holdSeconds = String(Int(HoldToConfirmButton.holdDuration))
    static let holdToEnableHint = "赤いボタンを " + holdSeconds + " 秒長押しすると有効になります。途中で離すと取り消します"
    static let holdKeepPressing = "そのまま押し続けてください…"
    static let deletionUnavailable = "設定を読み込めていないため、いまは操作できません"

    // F-65: カード型のパネルと、popover の中の画面（PLAN §8.12）
    static let buttonBack = "戻る"
    static let screenSettings = "設定"
    static let rowDeletion = "元音声の削除"
    static let rowDetails = "詳細・診断"
    static let sectionDiagnostics = "診断"
    static let sectionBacklog = "後追い"
    static let deletionOn = "有効"
    static let deletionOff = "無効"
    static func attentionMore(_ count: Int) -> String { "ほか " + String(count) + " 件" }
    /// 「はじめに」の見出しの右（完了した数 / 見えている数）
    static func onboardingProgress(done: Int, total: Int) -> String { String(done) + "/" + String(total) }
    /// 状態の見出しの 2 行目
    static func statusDetailLine(lastConnected: String, backlog: String) -> String {
        labelLastConnected + " " + lastConnected + " · " + backlog
    }
    static func deviceFreeLine(_ value: String) -> String { labelDeviceFree + " " + value }

    // F-66: 今すぐ要約（PLAN §5.4・§8.12 の 1。状態の見出しの小さなボタン）
    static let buttonSummarizeNow = "今すぐ要約"
    /// 閉じた Session の数（Session は 1 日 1 つなので「日分」）。0 のときは summarizeNowNothing を使う
    static func summarizeNowStarted(_ days: Int) -> String { String(days) + " 日分を要約します" }
    static let summarizeNowNothing = "未要約の録音はありません"

    // T-32: 要対応と詳細（PLAN §8.12 の 2 と 8）
    static let buttonRunDiagnostics = "診断を実行"
    static let buttonRunLLMProbe = "LLM の疎通確認"
    static let diagnosticsRunning = "診断を実行しています…"
    static let probeRunning = "LLM に問い合わせています…"
    static let labelStatusDetails = "状態の詳細"

    /// PLAN §8.10 の model_download_failed の reason に対応する文言
    static func modelError(_ e: ModelError) -> String {
        switch e {
        case .badHost: "配布元の URL が想定外です"
        case .badFileName: "ファイル名が使えません"
        case .sha256Mismatch: "SHA-256 が一致しません（壊れています。もう一度入手してください）"
        case .sizeMismatch: "サイズが一致しません（壊れています。もう一度入手してください）"
        case .http(let code): "配布元が HTTP " + String(code) + " を返しました"
        case .network: "ネットワークに接続できません"
        case .cancelled: "取り消しました"
        case .io(let m): "ファイルを扱えません: " + m
        }
    }
}
