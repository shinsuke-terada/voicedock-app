// パネルの文言（日本語のみ。PLAN §8.12「文言は Strings.swift に集める」）。
// 後続のチケット（T-31 / T-32 / T-40 / T-41）はこのファイルに自分の節の文言を足す。
import VDCore
import VDLLM
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
    /// F-84: 単一起動のロックを開けない（別のインスタンスが動いているのではない）
    static func bootFailureInstanceLock(path: String, reason: String) -> String {
        "単一起動のロック（" + path + "）を開けません: " + reason
    }

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

    // F-84: 起動したときの値のまま動いている設定（PLAN §8.12 の 8・§8.15。自動では再起動しない。時刻帯の変更は促さない。RK-32）
    static let restartPendingTitle = "次の設定は起動したときの値のまま動いています。「設定を読み直す」では変わらず、再起動すると変わります"
    /// 主画面の「詳細・診断」の行の右に出す短い印
    static let restartPendingRow = "再起動で反映される設定あり"
    static func restartPending(_ d: EffectiveSettings.Difference) -> String {
        switch d {
        case .timeZone(let running, let configured):
            "時刻帯: 起動したときの " + running + " のまま（設定は " + configured + "）。取り込みの時刻とログは起動したときの時刻帯、"
                + "ほかの処理は設定の時刻帯で動いています。使い始めた後に時刻帯を変えると記録の時刻が混ざるので、"
                + "変えるつもりがなければ設定を元に戻してください"
        case .logLevel(let running, let configured):
            "ログのレベル: 起動したときの " + logLevelWord(running) + " のまま（設定は " + logLevelWord(configured) + "）"
        case .unsafeLogContent(true):
            "ログに本文を出す設定: 起動したときの「出す」のまま。再起動するまで、DEBUG の行には本文が出続けます"
        case .unsafeLogContent(false):
            "ログに本文を出す設定: 起動したときの「出さない」のまま"
        }
    }
    /// ログのレベルの表記（行に出す語から空白を除いたもの。config.json の logging.level と同じ語）
    static func logLevelWord(_ level: LogLevel) -> String { String(level.token.filter { $0 != " " }) }

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
    /// 削除が有効な間のメニューバーのアイコンの説明（赤い点は読み上げられないので説明に足す。F-91）
    static func iconDescriptionWithDeletion(_ state: IconState) -> String {
        iconDescription(state) + "。" + iconTrashDescription
    }

    // F-92: 要約プロンプトの編集
    static let sectionPrompts = "要約プロンプト"
    static let buttonEditPrompts = "要約プロンプトを編集…"
    static let promptsNote = "LLM に渡す指示の本文を変えられます。未編集なら同梱の既定の本文を使います"
    static let promptEditorTitle = "要約プロンプトの編集"
    static let promptKindPicker = "プロンプトの種類"
    static func promptKindLabel(_ kind: PromptKind) -> String {
        switch kind {
        case .analyze: "1 回で要約"
        case .map: "分割して要約（Map）"
        case .reduce: "まとめ（Reduce）"
        }
    }
    static func promptKindNote(_ kind: PromptKind) -> String {
        switch kind {
        case .analyze: "1 日分の文字起こしが 1 回の要求に収まるときに使います"
        case .map: "長い日を分割したそれぞれの部分に使います（まとめきれないときの中間のまとめにも使います）"
        case .reduce: "分割して要約した結果を 1 日分にまとめるときに使います"
        }
    }
    static let promptEditorHint =
        "{schema_block}（JSON の形の見本）と {custom_instructions}（追加の指示）は消さないでください。"
        + "変更は次に要約する日から使います（要約済みの日は作り直しません）"
    static let buttonResetPrompt = "既定に戻す"
    static let buttonSavePrompts = "保存"
    static let promptsSaved = "保存しました"
    static let promptsUnsaved = "未保存の変更があります"
    static let promptsUnavailable = "設定または同梱のプロンプトを読めません。「詳細・診断」の「設定を読み直す」を試してください"

    // T-31: はじめに（PLAN §8.12 の 3）
    static let onboardingVault = "Vault を選ぶ"
    static let onboardingWhisper = "Whisper モデルを入手する"
    static let onboardingLLM = "LLM を選んで入手する"
    static let onboardingLoginItem = "ログイン時に起動する"
    static let onboardingDeviceName = "デバイスの名前を変える"
    static let onboardingLater = "今はしない"
    /// アプリは改名しない（DEV-10）。手順を見せるだけ。既定の include（["DJIMIC3"]）と食い違わない文言（F-81。PLAN §8.12）
    static func renameInstructions(_ names: [String]) -> String {
        names.joined(separator: "、")
            + " という名前のデバイスがつながっています。VoiceDock が取り込むのは、名前が設定の device.includeVolumes"
            + "（既定は DJIMIC3 だけ。空なら全部）に合うデバイスです。VoiceDock はデバイスに一切書き込みません。"
            + "DJI Mic 3 なら、次のどちらかを利用者が行ってください。\n"
            + "1. Finder のサイドバーでデバイスを選び、名前をゆっくり 2 回クリックして「DJIMIC3」に変えます。"
            + "変えたらデバイスを取り外して、もう一度つなぎ直してください\n"
            + "2. 名前を変えずに使うなら、config.json の device.includeVolumes にこの名前を足して、「設定を読み直す」を押してください\n"
            + "名前が「DJIMIC3 1」のように番号付きなら、名前は変えずに取り外して、もう一度つなぎ直してください。"
            + "録音の写しを入れたメモリなど DJI Mic 3 でなければ、何もしなくてかまいません（取り込みも削除もしません）"
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
    // T-51: 話者分離（PLAN §8.12 の 6。F-89）
    static let labelDiarization = "話者分離（誰が話したか）"
    static let diarizationNote = "オンにした後に文字起こしする録音から、Raw ノートを「話者A: …」の行に分けます。精度は録音の条件で変わります。"
    static func diarizationMissing(_ parts: [String]) -> String {
        "話者分離の部品がありません（\(parts.joined(separator: "、"))）。話者なしで文字起こしします"
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

    // F-84: 削除モジュールの更新（PLAN §8.9.3 の 5「更新は有効化フローをもう一度通す」）と、無効化の待ち（PLAN §8.9.8）
    static let buttonUpdateReaper = "更新する"
    static let holdToUpdateHint =
        "削除モジュールの版がアプリと違うため、削除を止めています。赤いボタンを " + holdSeconds
        + " 秒長押しすると、有効化をもう一度通して入れ直します。途中で離すと取り消します"
    /// 「更新する」の読み上げの補足（F-84）
    static let holdToUpdateAccessibilityHint = "赤いボタンを " + holdSeconds + " 秒長押しすると更新します。途中で離すと取り消します"
    static let disablingDeletion = "読み取り専用へ戻しています…"

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
    /// 閉じた Session の数（Session の数。溢れた分の #2 もあるので「日分」ではなく「件」）。0 のときは summarizeNowNothing を使う
    static func summarizeNowStarted(_ days: Int) -> String { "要約を始めました（" + String(days) + " 件）" }
    static let summarizeNowNothing = "新しく要約する録音はありません"

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
