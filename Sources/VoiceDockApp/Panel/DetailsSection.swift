// 「詳細・診断」の画面の中身（PLAN §8.12 の 8）。診断・LLM の疎通確認・状態の詳細・設定とログ・版・後追い（T-41）。
import SwiftUI
import VDPipeline

/// 「詳細・診断」の画面の中身。状態の詳細は、この画面に入ったときだけ読む（AppModel.show。F-65）。
struct DetailsSection: View {
    let model: AppModel

    var body: some View {
        SectionBox(title: Strings.sectionDiagnostics) {
            HStack(spacing: 6) {
                Button(Strings.buttonRunDiagnostics) { Task { await model.runDiagnostics() } }
                    .disabled(model.diagnostics == .running)
                Button(Strings.buttonRunLLMProbe) { Task { await model.runLLMProbe() } }
                    .disabled(model.probe == .running)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            results(model.diagnostics, running: Strings.diagnosticsRunning, summary: true)
            results(model.probe, running: Strings.probeRunning, summary: false)
        }
        if let report = model.snapshot.statusReport {
            SectionBox(title: Strings.labelStatusDetails) {
                ForEach(Array(report.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(.caption, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        SectionBox(title: Strings.sectionDetails) {
            HStack(spacing: 6) {
                Button(Strings.buttonRetry) { Task { await model.requeueManual() } }
                Button(Strings.buttonReloadConfig) { Task { await model.reloadConfig() } }
            }
            HStack(spacing: 6) {
                Button(Strings.buttonRevealConfig) { model.revealConfigInFinder() }
                Button(Strings.buttonRevealLogs) { model.revealLogsInFinder() }
            }
            if let reload = model.reloadResult {
                switch reload {
                case .ok: Text(Strings.reloadOK).font(.caption).foregroundStyle(.secondary)
                case .invalid(let v): Text(Strings.reloadInvalid(v.count)).font(.caption).foregroundStyle(.red)
                }
            }
            // 起動したときの値のまま動いている設定（read のたびに作る値。自動では再起動しない。F-84）
            let pending = model.snapshot.settingsAwaitingRestart
            if !pending.isEmpty {
                Text(Strings.restartPendingTitle).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(pending.enumerated()), id: \.offset) { _, d in
                    Text(Strings.restartPending(d)).font(.caption).foregroundStyle(.secondary).padding(.leading, 14)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        SectionBox(title: Strings.sectionBacklog) {
            BacklogControls(model: model)
        }
        Text(model.versionLine).font(.caption).foregroundStyle(.secondary)
    }

    /// 結果は「記号 ラベル」と、字下げした details。診断は末尾にサマリ
    @ViewBuilder
    private func results(_ state: AppModel.DiagnosticsPanelState, running: String, summary: Bool) -> some View {
        switch state {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(running).font(.caption).foregroundStyle(.secondary)
            }
        case .done(let rs):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(rs.enumerated()), id: \.offset) { _, r in
                    Text(r.status.mark + " " + r.label).font(.caption)
                    ForEach(Array(r.details.enumerated()), id: \.offset) { _, d in
                        Text(d).font(.caption).foregroundStyle(.secondary).padding(.leading, 14)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if summary { Text(Diagnostics.summary(rs)).font(.caption.weight(.semibold)) }
            }
        }
    }
}
