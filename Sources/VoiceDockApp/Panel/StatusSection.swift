// 状態の節（PLAN §8.12 の 1）。1 行の状態・最終接続・未処理・デバイスの空き容量。
import SwiftUI

/// 状態の節（PLAN §8.12 の 1）。このチケットが中身を書く唯一の節。
struct StatusSection: View {
    let model: AppModel

    var body: some View {
        SectionBox(title: Strings.sectionStatus) {
            Text(model.statusLine).font(.headline)
            LabeledRow(Strings.labelLastConnected, model.lastConnectedLine)
            LabeledRow(Strings.labelBacklog, model.backlogLine)
            if let free = model.deviceFreeLine { LabeledRow(Strings.labelDeviceFree, free) }
        }
    }
}

/// ラベルと値の 1 行（ラベルは .secondary）。
private struct LabeledRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}
