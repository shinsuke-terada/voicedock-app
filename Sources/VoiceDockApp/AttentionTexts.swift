// 要対応の説明とボタンの文言（PLAN §8.11。T-32 §4.10 の逐語）。
import Foundation
import VDCore
import VDNotes
import VDPipeline

/// 要対応の説明とボタンの文言（日本語のみ）。
enum AttentionTexts {
    static let tccFolders = "システム設定 → プライバシーとセキュリティ → ファイルとフォルダ で VoiceDock に許可してください"
    static let fetchModel = "「モデル」で入手してください"
    static let reinstall = "アプリが壊れています。入れ直してください"

    static func title(_ item: AttentionItem) -> String {
        switch item {
        case .configInvalid: "設定にエラーがあります"
        case .vaultNotConfigured: "Vault が選ばれていません"
        case .vaultUnavailable: "Vault が使えません"
        case .modelMissing(.whisper): "Whisper モデルがありません"
        case .modelMissing(.vad): "VAD モデルがありません"
        case .modelMissing(.llm): "LLM モデルがありません"
        case .llmNotSelected: "LLM が選ばれていません"
        case .llmInsufficientMemory: "LLM にメモリが足りません"
        case .toolMissing(.whisperCLI): "whisper-cli がありません"
        case .toolMissing(.llamaServer): "llama-server がありません"
        case .deviceNotListable(let n): n + " の中身を読めません"
        case .deviceNeedsReplug(let n): n + " を挿し直してください"
        case .deviceNameInvalid(let n): n + " は使えない名前です"
        case .ingestSilent: "取り込みが止まっているようです"
        case .diskSpaceLow: "空き容量が足りません"
        case .lockMismatch: "削除の設定が食い違っています"
        case .reaperUpdateRequired: "削除モジュールの更新が必要です"
        case .undeletableSources(let n): "消せなかった録音 " + String(n) + " 本"
        case .rawNoteBlocked(let n): "書き直せない Raw ノート " + String(n) + " 件"
        }
    }

    /// path と marker は vaultUnavailable の説明にだけ使う（VaultStatus.message にそのまま渡す）
    static func detail(_ item: AttentionItem, path: String, marker: String) -> String {
        switch item {
        case .configInvalid: "設定ファイルを直してから「設定を読み直す」を押してください"
        case .vaultNotConfigured: "「保存先（Vault）」で Obsidian の Vault を選んでください"
        case .vaultUnavailable(let st):
            if st == .notReadable(errno: EPERM) {
                st.message(path: path, marker: marker) + "\n" + tccFolders
            } else {
                st.message(path: path, marker: marker)
            }
        case .modelMissing: fetchModel
        case .llmNotSelected: "「モデル」で選んでください"
        case .llmInsufficientMemory: "「モデル」で小さいモデルを選んでください"
        case .toolMissing: reinstall
        case .deviceNotListable: "システム設定 → プライバシーとセキュリティ → ファイルとフォルダ → VoiceDock → リムーバブルボリューム"
        case .deviceNeedsReplug: "同じ名前のボリュームがあるか、マウント先の名前が変わっています。取り外して、もう一度つなぎ直してください"
        case .deviceNameInvalid:
            "Finder でデバイスの名前を「DJIMIC3」などに変えてから、つなぎ直してください（VoiceDock はデバイスに書き込みません）"
        case .ingestSilent: "デバイスはつながっていますが、しばらく何も起きていません。ログを確かめてください"
        case .diskSpaceLow: "不要なファイルを消すか、staging の上限を上げてください"
        case .lockMismatch: "アプリと reaper.conf の設定が合いません。「元音声の削除」を開いて無効化し直してください"
        case .reaperUpdateRequired:
            // F-84: 削除が有効な間は「元音声の削除」の画面に長押しの「更新する」が出る（PLAN §8.9.3 の 5）
            "「元音声の削除」を開いて、「" + Strings.buttonUpdateReaper + "」を " + Strings.holdSeconds + " 秒長押ししてください"
        case .undeletableSources:
            // F-78: 5a（アプリの検査）は直せば再評価できるが、5b（削除モジュールの拒否）は再評価しても同じなので後追いを勧めない
            "消せない状態が続いたので、元の録音を消さずに完了にしました。原因は「詳細・診断」の状態の詳細で確かめられます。"
                + "Raw ノート・文字起こし・元のファイルの問題なら、直してから「過去分を削除対象にする」で再評価できます。"
                + "削除モジュールの検証で拒否され続けたものは、再評価しても同じ結果になります。手で消す前に、Raw ノートと文字起こしが残っていることを確かめてください"
        case .rawNoteBlocked:
            "文字起こしを読めなくなった録音があり、Raw ノートを書き直すとその本文が消えるので、書き直さずに止めています"
                + "（その後の録音はまだ Raw ノートに載っていません）。文字起こしのファイルをバックアップから戻すか、"
                + "Obsidian でその Raw ノートの名前を変えてから（新しい Raw ノートが書かれ、古い本文は名前を変えたノートにそのまま残ります）、"
                + "「詳細・診断」の「再試行」を押してください"
        }
    }

    static func button(_ action: AttentionAction) -> String {
        switch action {
        case .revealConfig: "設定ファイルを Finder で表示"
        case .reloadConfig: "設定を読み直す"
        case .chooseVault: "Vault を選び直す"
        case .openSystemSettings: "システム設定を開く"
        case .openModels: "モデルの節を開く"
        case .openDeletionFlow: "有効化フローを開く"
        case .runDiagnostics: Strings.buttonRunDiagnostics
        case .openDetails: "詳細・診断を開く"
        }
    }
}
