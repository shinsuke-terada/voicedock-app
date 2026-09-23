// 診断・LLM の疎通確認・状態の詳細・要対応の操作（PLAN §8.11・§8.12 の 2 と 8）。
import Foundation
import VDPipeline

extension AppModel {
    /// 「診断を実行」。実行中は二重に押せない。閉じた後に届いた結果は捨てる（panelDidClose が idle に戻し世代を進める。F-72）。
    /// 閉じて開き直した後に押されても、閉じる前に始めた診断が終わるまで次を起動しない（診断を同時に 2 本走らせない。F-72）
    func runDiagnostics() async {
        guard diagnostics != .running else { return }
        diagnostics = .running
        diagnosticsGeneration += 1
        let generation = diagnosticsGeneration
        let previous = diagnosticsTask
        let services = self.services
        let task = Task { () -> [DiagnosticResult] in
            _ = await previous?.value
            return await services.runDiagnostics()
        }
        diagnosticsTask = task
        let results = await task.value
        guard generation == diagnosticsGeneration else { return }
        diagnostics = .done(results)
    }

    /// 「LLM の疎通確認」（DR-09）。Worker の直列ループに 1 件の仕事として入れる（PLAN §8.11）。実行中は二重に押せない
    func runLLMProbe() async {
        guard probe != .running else { return }
        probe = .running
        probeGeneration += 1
        let generation = probeGeneration
        await services.enqueue(
            .llmProbe(reply: { [weak self] r in
                Task { @MainActor in self?.receiveProbe(r, generation: generation) }
            }))
    }

    /// DR-09 の返事（閉じた後の返事・前の世代の返事は捨てる）
    func receiveProbe(_ r: DiagnosticResult, generation: Int) {
        guard probe == .running, generation == probeGeneration else { return }
        probe = .done([r])
    }

    /// 「詳細」の開閉。開いたときだけ状態の詳細を読み直す（閉じている間は inbox も staging も走査しない）
    func toggleDetails() async {
        detailsExpanded.toggle()
        guard detailsExpanded else {
            setStatusReport(nil)
            return
        }
        let report = await services.statusReport()
        // 待っている間に閉じられたら差し込まない
        guard detailsExpanded else { return }
        setStatusReport(report)
    }

    /// 要対応のボタン（PLAN §8.11 の「操作ボタン」の列）
    func perform(_ action: AttentionAction) {
        switch action {
        case .revealConfig: revealConfigInFinder()
        case .reloadConfig: Task { await reloadConfig() }
        case .chooseVault: Task { await chooseVault() }
        case .openSystemSettings: openSystemSettingsPrivacyFilesAndFolders()
        case .openModels:
            // モデルの節は主画面にある（F-65）
            modelsHighlighted = true
            Task { await show(.main) }
        case .openDeletionFlow:
            deletionHighlighted = true
            Task { await show(.deletion) }
        case .runDiagnostics:
            Task {
                await show(.details)
                await runDiagnostics()
            }
        case .openDetails:
            // 状態の詳細は、この画面に入ったときに読む（F-65）
            Task { await show(.details) }
        }
    }

    /// システム設定の「ファイルとフォルダ」を開く
    func openSystemSettingsPrivacyFilesAndFolders() { services.openSystemSettingsPrivacyFilesAndFolders() }
}
