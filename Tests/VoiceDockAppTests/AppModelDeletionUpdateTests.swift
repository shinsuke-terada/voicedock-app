// 「元音声の削除」の更新・無効化の待ち・閉じたときの戻し（F-84・issue #119 の G6・G11・G13）。ビューは作らない。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDPipeline

@testable import VoiceDockApp

@MainActor
@Suite("AppModel+Deletion の更新と無効化の待ち（F-84）")
struct AppModelDeletionUpdateTests {
    /// 削除の値（reaper の版を差し替えられる）
    static func panel(appEnabled: Bool, conf: LockDisplay.ConfState, reaper: ReaperStatus) -> DeletionPanelState {
        DeletionPanelState(
            display: LockDisplay(
                appEnabled: appEnabled, confState: conf, reaper: reaper, mountMode: appEnabled ? "rw" : "ro",
                devices: [], readiness: .disabled(DeletionReason.reaperInvalid)),
            deleteSkippedSource: false)
    }

    static let mismatch = ReaperStatus.versionMismatch(found: "0.9.0")

    static func snapshot(deletion: DeletionPanelState?, attention: [AttentionItem]) -> AppSnapshot {
        var s = AppModelTests.present()
        s.deletion = deletion
        s.attention = attention
        return s
    }

    static func model(_ s: AppSnapshot) async -> (AppModel, FakeServices) {
        let fake = FakeServices(s)
        let model = AppModelTests.makeModel(fake)
        await model.refresh()
        return (model, fake)
    }

    // MARK: G6 削除モジュールの更新

    @Test("F-84 削除が有効で削除モジュールの版が違えば「更新する」を出す")
    func updateShownWhileEnabled() async {
        let (model, _) = await Self.model(
            Self.snapshot(
                deletion: Self.panel(appEnabled: true, conf: .enabled, reaper: Self.mismatch),
                attention: [.reaperUpdateRequired]))
        #expect(model.showsReaperUpdate == true)
        #expect(model.showsTrash == true)
        #expect(model.deletion?.notices == ["削除モジュールの更新が必要です"])
    }

    @Test("F-84 削除が無効なら版が違っても「更新する」を出さない（「有効にする」の側に任せる）")
    func updateHiddenWhileDisabled() async {
        let (model, _) = await Self.model(
            Self.snapshot(
                deletion: Self.panel(appEnabled: false, conf: .disabled, reaper: Self.mismatch),
                attention: [.reaperUpdateRequired]))
        #expect(model.showsReaperUpdate == false)
        #expect(model.showsTrash == false)
    }

    @Test("F-84 reaper.conf だけが有効な中途の状態では「更新する」を出さない（有効化で範囲を広げない）")
    func updateHiddenInTheHalfState() async {
        let (model, _) = await Self.model(
            Self.snapshot(
                deletion: Self.panel(appEnabled: false, conf: .enabled, reaper: Self.mismatch),
                attention: [.reaperUpdateRequired]))
        #expect(model.showsTrash == true)
        #expect(model.showsReaperUpdate == false)
    }

    @Test("F-84 設定エラー中（削除の値が無い）は「更新する」を出さない")
    func updateHiddenWithoutConfig() async {
        var s = Self.snapshot(deletion: nil, attention: [.configInvalid, .reaperUpdateRequired])
        s.configPresent = false
        s.deletionResidual = true
        let (model, _) = await Self.model(s)
        #expect(model.showsReaperUpdate == false)
        #expect(model.showsDisableButton == true)
    }

    @Test("F-84 要対応が 0 件（版が合っている）なら、削除が有効でも「更新する」を出さない（TEST-28）")
    func updateHiddenWithoutAttention() async {
        let (model, _) = await Self.model(
            Self.snapshot(
                deletion: Self.panel(appEnabled: true, conf: .enabled, reaper: .valid(version: "0.1.0")),
                attention: []))
        #expect(model.showsReaperUpdate == false)
        #expect(model.deletion?.notices == [])
    }

    @Test("F-84 「更新する」の長押しの完了は有効化フローをもう一度通す（定数の確認語 ENABLE。自動で複製し直さない）")
    func updateRunsTheEnableFlowAgain() async {
        let (model, fake) = await Self.model(
            Self.snapshot(
                deletion: Self.panel(appEnabled: true, conf: .enabled, reaper: Self.mismatch),
                attention: [.reaperUpdateRequired]))
        // refresh だけでは何も有効化しない
        #expect(fake.enableConfirmations == [])
        fake.set(
            Self.snapshot(
                deletion: Self.panel(appEnabled: true, conf: .enabled, reaper: .valid(version: "0.1.0")),
                attention: []))
        _ = await model.enableDeletion()
        #expect(fake.enableConfirmations == ["ENABLE"])
        #expect(model.showsReaperUpdate == false)
    }

    @Test("F-84 更新と無効化の待ちの文言（ボタン・長押しの案内・要対応の説明）")
    func updateTexts() {
        #expect(Strings.buttonUpdateReaper == "更新する")
        #expect(
            Strings.holdToUpdateHint
                == "削除モジュールの版がアプリと違うため、削除を止めています。赤いボタンを 3 秒長押しすると、有効化をもう一度通して入れ直します。途中で離すと取り消します")
        #expect(Strings.disablingDeletion == "読み取り専用へ戻しています…")
        #expect(AttentionTexts.title(.reaperUpdateRequired) == "削除モジュールの更新が必要です")
        #expect(
            AttentionTexts.detail(.reaperUpdateRequired, path: "/v", marker: ".obsidian")
                == "「元音声の削除」を開いて、赤いボタンの長押しで有効化をやり直してください")
        #expect(AttentionTexts.button(.openDeletionFlow) == "有効化フローを開く")
    }

    // MARK: G11 無効化の待ち

    @Test("F-84 無効化が再マウントを待つ間は「読み取り専用へ戻しています…」の印が立ち、終われば下りる")
    func disablingFlagWhileWaiting() async {
        let (model, fake) = await Self.model(
            Self.snapshot(deletion: AppModelTests.deletionOn, attention: []))
        #expect(model.deletionDisabling == false)
        fake.setHoldDisable(true)
        let disabling = Task { await model.disableDeletion() }
        #expect(await AppModelTests.waitUntil { fake.disableCount == 1 })
        #expect(model.deletionDisabling == true)
        #expect(model.deletionBusy == true)
        fake.releaseDisable()
        _ = await disabling.value
        #expect(model.deletionDisabling == false)
        #expect(model.deletionBusy == false)
    }

    // MARK: G13 閉じたときの戻し

    @Test("F-84 閉じたら要対応の枠（モデル・削除）と有効化の失敗の表示を戻す")
    func closingResetsHighlightsAndEnableError() async {
        let fake = FakeServices(AppModelTests.present())
        fake.setEnableResult(.failure(.signature))
        let model = AppModelTests.makeModel(fake)
        _ = await model.enableDeletion()
        #expect(model.enableError == .signature)
        model.perform(.openModels)
        model.perform(.openDeletionFlow)
        #expect(model.modelsHighlighted == true)
        #expect(model.deletionHighlighted == true)
        model.panelDidClose()
        #expect(model.modelsHighlighted == false)
        #expect(model.deletionHighlighted == false)
        #expect(model.enableError == nil)
    }

    @Test("F-84 閉じても無効化に失敗した段は残す（「無効にする」を出し続ける）")
    func closingKeepsFailedDisableStages() async {
        let fake = FakeServices(AppModelTests.present())
        fake.setDisableResult(["remove_reaper"])
        let model = AppModelTests.makeModel(fake)
        _ = await model.disableDeletion()
        model.panelDidClose()
        #expect(model.disableFailedStages == ["remove_reaper"])
        #expect(model.showsDisableButton == true)
    }
}
