// 「詳細」の節（PLAN §8.12 の 8）。診断・LLM の疎通確認・状態の詳細・設定とログ・版。
import SwiftUI
import VDPipeline

/// 「詳細」の節。開いたときだけ状態の詳細を読む（閉じている間は inbox も staging も走査しない）。
struct DetailsSection: View {
    let model: AppModel

    var body: some View {
        DisclosureGroup(
            Strings.sectionDetails,
            isExpanded: Binding(
                get: { model.detailsExpanded },
                set: { open in
                    if open != model.detailsExpanded { Task { await model.toggleDetails() } }
                })
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Button(Strings.buttonRunDiagnostics) { Task { await model.runDiagnostics() } }
                    .disabled(model.diagnostics == .running)
                results(model.diagnostics, running: Strings.diagnosticsRunning, summary: true)
                Button(Strings.buttonRunLLMProbe) { Task { await model.runLLMProbe() } }
                    .disabled(model.probe == .running)
                results(model.probe, running: Strings.probeRunning, summary: false)
                if let report = model.snapshot.statusReport {
                    Text(Strings.labelStatusDetails).font(.subheadline).foregroundStyle(.secondary)
                    ForEach(Array(report.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced))
                    }
                }
                Button(Strings.buttonRetry) { Task { await model.requeueManual() } }
                Button(Strings.buttonRevealConfig) { model.revealConfigInFinder() }
                Button(Strings.buttonRevealLogs) { model.revealLogsInFinder() }
                Button(Strings.buttonReloadConfig) { Task { await model.reloadConfig() } }
                Text(model.versionLine).foregroundStyle(.secondary)
                // T-41 が BacklogControls(model: model) を足す
            }
        }
    }

    /// 結果は「記号 ラベル」と、字下げした details。診断は末尾にサマリ
    @ViewBuilder
    private func results(_ state: AppModel.DiagnosticsPanelState, running: String, summary: Bool) -> some View {
        switch state {
        case .idle:
            EmptyView()
        case .running:
            Text(running).foregroundStyle(.secondary)
        case .done(let rs):
            ForEach(Array(rs.enumerated()), id: \.offset) { _, r in
                Text(r.status.mark + " " + r.label)
                ForEach(Array(r.details.enumerated()), id: \.offset) { _, d in
                    Text("    " + d).fixedSize(horizontal: false, vertical: true)
                }
            }
            if summary { Text(Diagnostics.summary(rs)) }
        }
    }
}
