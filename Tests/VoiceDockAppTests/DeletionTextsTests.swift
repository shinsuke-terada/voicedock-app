// 「元音声の削除」の節の文言（Strings の T-40 分と DeletionStrings）が T-40 §4.5 の表と逐語で一致することのテスト。
import Testing
import VDCore
import VDPipeline

@testable import VoiceDockApp

@Suite("元音声の削除の文言")
struct DeletionTextsTests {
    @Test("ボタンと無効化の失敗の文言は逐語")
    func labelsAreVerbatim() {
        #expect(Strings.sectionDeletion == "元音声の削除")
        #expect(Strings.buttonEnableDeletion == "有効にする")
        #expect(Strings.buttonEnableSkippedDeletion == "無音・重複も消す")
        #expect(Strings.buttonDisableDeletion == "無効にする")
        #expect(Strings.disableFailed(["reaper_conf", "remount"]) == "無効にできなかった段: reaper_conf, remount")
    }

    @Test("PLAN §8.9.8 の事前確認・確認語・挿し直しの案内は逐語")
    func planTextsAreVerbatim() {
        #expect(DeletionStrings.confirmVerified == "1 日以上の運用で Raw ノートが正しく作られていることを確かめましたか")
        #expect(DeletionStrings.confirmIrreversible == "消した録音は戻りません")
        #expect(DeletionStrings.confirmationWord == "ENABLE")
        #expect(DeletionStrings.reinsertNotice == "読み書きできるようになるのはデバイスを挿し直した後です")
    }

    static let violation = ConfigViolation(
        rule: "CV-39", code: .configInvalidValue, keyPath: "<file>", message: "書けません")

    @Test(
        "EnableError の各ケースの文言は逐語（T-40 §4.5 の表）",
        arguments: [
            (EnableError.notConfirmed, "有効にできませんでした: 赤いボタンを 3 秒長押ししてください"),
            (EnableError.install("X"), "有効にできませんでした: 削除モジュールを置けません（X）"),
            (EnableError.signature, "有効にできませんでした: 削除モジュールの署名を確かめられません"),
            (EnableError.reaperConfWrite("X"), "有効にできませんでした: reaper.conf を書けません（X）"),
            (EnableError.config([]), "有効にできませんでした: 元音声の削除が有効になっていません"),
            (
                EnableError.config([violation]),
                "有効にできませんでした: 設定に書けません（CV-39  CONFIG_INVALID_VALUE  <file>: 書けません）"
            ),
            (EnableError.configNotLoaded, "有効にできませんでした: 設定が読み込まれていません"),
            (
                EnableError.rollback(stages: ["reaper_conf", "copy_reaper"]),
                "有効にできませんでした: 元に戻せなかった段があります（reaper_conf, copy_reaper）"
            ),
        ])
    func enableFailureTextsAreVerbatim(_ error: EnableError, _ expected: String) {
        #expect(Strings.enableFailed(error) == expected)
    }

    @Test("TEST-28 段が 0 件でも無効化の失敗の文言は落ちない")
    func disableFailedWithNoStages() {
        #expect(Strings.disableFailed([]) == "無効にできなかった段: ")
    }
}
