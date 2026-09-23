// 要対応の文言と操作の対応のテスト（T-32 §5.9）。文言は §4.10 の表の逐語。
import Darwin
import Foundation
import Testing
import VDCore
import VDNotes
import VDPipeline

@testable import VoiceDockApp

@Suite("AttentionTexts")
struct AttentionTextsTests {
    static let settings = "システム設定 → プライバシーとセキュリティ → ファイルとフォルダ で VoiceDock に許可してください"

    /// §4.10 の表（項目・題・説明）
    static let table: [(AttentionItem, String, String)] = [
        (.configInvalid, "設定にエラーがあります", "設定ファイルを直してから「設定を読み直す」を押してください"),
        (.vaultNotConfigured, "Vault が選ばれていません", "「保存先（Vault）」で Obsidian の Vault を選んでください"),
        (.vaultUnavailable(.missingRoot), "Vault が使えません", "/v がありません"),
        (.modelMissing(.whisper), "Whisper モデルがありません", "「モデル」で入手してください"),
        (.modelMissing(.vad), "VAD モデルがありません", "「モデル」で入手してください"),
        (.modelMissing(.llm), "LLM モデルがありません", "「モデル」で入手してください"),
        (.llmNotSelected, "LLM が選ばれていません", "「モデル」で選んでください"),
        (.llmInsufficientMemory, "LLM にメモリが足りません", "「モデル」で小さいモデルを選んでください"),
        (.toolMissing(.whisperCLI), "whisper-cli がありません", "アプリが壊れています。入れ直してください"),
        (.toolMissing(.llamaServer), "llama-server がありません", "アプリが壊れています。入れ直してください"),
        (
            .deviceNotListable("DJIMIC3"), "DJIMIC3 の中身を読めません",
            "システム設定 → プライバシーとセキュリティ → ファイルとフォルダ → VoiceDock → リムーバブルボリューム"
        ),
        (
            .deviceNeedsReplug("DJIMIC3"), "DJIMIC3 を挿し直してください",
            "同じ名前のボリュームがあるか、マウント先の名前が変わっています。取り外して、もう一度つなぎ直してください"
        ),
        (
            .deviceNameInvalid("NO NAME"), "NO NAME は使えない名前です",
            "Finder でデバイスの名前を「DJIMIC3」などに変えてから、つなぎ直してください（VoiceDock はデバイスに書き込みません）"
        ),
        (.ingestSilent, "取り込みが止まっているようです", "デバイスはつながっていますが、しばらく何も起きていません。ログを確かめてください"),
        (.diskSpaceLow, "空き容量が足りません", "不要なファイルを消すか、staging の上限を上げてください"),
        (
            .lockMismatch, "削除の設定が食い違っています",
            "アプリと reaper.conf の設定が合いません。「元音声の削除」を開いて無効化し直してください"
        ),
        (.reaperUpdateRequired, "削除モジュールの更新が必要です", "「元音声の削除」を開いて有効化をやり直してください"),
        (
            .undeletableSources(3), "消せなかった録音 3 本",
            "消せない状態が続いたので、元の録音を消さずに完了にしました。原因は「詳細・診断」の状態の詳細で確かめられます。Raw ノート・文字起こし・元のファイルの問題なら、直してから「過去分を削除対象にする」で再評価できます。削除モジュールの検証で拒否され続けたものは、再評価しても同じ結果になります。手で消す前に、Raw ノートと文字起こしが残っていることを確かめてください"
        ),
    ]

    @Test("題と説明が表と逐語で一致する")
    func titlesAndDetailsMatchTheTable() {
        for (item, title, detail) in Self.table {
            #expect(AttentionTexts.title(item) == title)
            #expect(AttentionTexts.detail(item, path: "/v", marker: ".obsidian") == detail)
        }
    }

    @Test("EPERM の Vault は許可の案内を足す")
    func vaultEPERMAddsTheSettingsLine() {
        let item = AttentionItem.vaultUnavailable(.notReadable(errno: EPERM))
        #expect(
            AttentionTexts.detail(item, path: "/v", marker: ".obsidian") == "/v を読めません（errno 1）\n" + Self.settings)
        #expect(
            AttentionTexts.detail(.vaultUnavailable(.notReadable(errno: EACCES)), path: "/v", marker: ".obsidian")
                == "/v を読めません（errno 13）")
    }

    @Test("ボタンの文言が 8 つとも逐語で一致する")
    func buttonsMatchTheTable() {
        let expected: [(AttentionAction, String)] = [
            (.revealConfig, "設定ファイルを Finder で表示"), (.reloadConfig, "設定を読み直す"), (.chooseVault, "Vault を選び直す"),
            (.openSystemSettings, "システム設定を開く"), (.openModels, "モデルの節を開く"), (.openDeletionFlow, "有効化フローを開く"),
            (.runDiagnostics, "診断を実行"), (.openDetails, "詳細・診断を開く"),
        ]
        for (action, text) in expected {
            #expect(AttentionTexts.button(action) == text)
        }
    }

    @Test("全ケースに題が在る（15 項目。F-61 で coexistenceBlocked を外し、F-69 で undeletableSources を足した）")
    func everyItemHasATitle() {
        let kinds = Set(Self.table.map { $0.0.order })
        #expect(kinds.count == 15)
        #expect(kinds == Set(0..<15))
        #expect(Self.table.allSatisfy { !AttentionTexts.title($0.0).isEmpty })
    }
}
