// 診断・LLM の疎通確認・状態の詳細・要対応の操作（PLAN §8.11・§8.12 の 2 と 8）。
import Foundation
import VDPipeline

extension AppModel {
    /// 「診断を実行」。実行中は二重に押せない
    func runDiagnostics() async {
        guard diagnostics != .running else { return }
        diagnostics = .running
        diagnostics = .done(await services.runDiagnostics())
    }

    /// 「LLM の疎通確認」（DR-09）。Worker の直列ループに 1 件の仕事として入れる（PLAN §8.11）。実行中は二重に押せない
    func runLLMProbe() async {
        guard probe != .running else { return }
        probe = .running
        await services.enqueue(
            .llmProbe(reply: { [weak self] r in
                Task { @MainActor in self?.receiveProbe(r) }
            }))
    }

    /// DR-09 の返事（閉じた後の返事は捨てる）
    func receiveProbe(_ r: DiagnosticResult) {
        guard probe == .running else { return }
        probe = .done([r])
    }

    /// 「詳細」の開閉。開いたときだけ状態の詳細を読み直す（閉じている間は inbox も staging も走査しない）
    func toggleDetails() async {
        detailsExpanded.toggle()
        guard detailsExpanded else {
            setStatusReport(nil)
            return
        }
        setStatusReport(await services.statusReport())
    }

    /// 要対応のボタン（PLAN §8.11 の「操作ボタン」の列）
    func perform(_ action: AttentionAction) {
        switch action {
        case .revealConfig: revealConfigInFinder()
        case .reloadConfig: Task { await reloadConfig() }
        case .chooseVault: Task { await chooseVault() }
        case .openSystemSettings: openSystemSettingsPrivacyFilesAndFolders()
        case .openModels: modelsHighlighted = true
        case .openDeletionFlow: deletionHighlighted = true
        }
    }

    /// システム設定の「ファイルとフォルダ」を開く
    func openSystemSettingsPrivacyFilesAndFolders() { services.openSystemSettingsPrivacyFilesAndFolders() }
}
