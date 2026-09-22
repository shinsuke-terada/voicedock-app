// 「はじめに」のカード（PLAN §8.12 の 3）。未完了がある間だけ。2 列のチェックと、右肩に「完了 / 全体」（F-65）。
import SwiftUI

/// 「はじめに」のカード。未完了で見える項目が 1 つも無ければ何も出さない。
/// ログイン時に起動（④）が未完了の間は、そのトグルと「今はしない」をこのカードに置く（完了後は ⚙ の画面）。
struct OnboardingSection: View {
    let model: AppModel

    var body: some View {
        let items = OnboardingEvaluator.items(model.snapshot).filter(\.visible)
        if items.contains(where: { !$0.done }) {
            SectionBox(
                title: Strings.sectionOnboarding,
                trailing: Strings.onboardingProgress(done: items.filter(\.done).count, total: items.count)
            ) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { i in
                        GridRow {
                            OnboardingCell(item: items[i])
                            if i + 1 < items.count {
                                OnboardingCell(item: items[i + 1])
                            } else {
                                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            }
                        }
                    }
                }
                if items.contains(where: { $0.step == .loginItem && !$0.done }) {
                    Divider()
                    HStack(alignment: .top) {
                        GeneralSection(model: model)
                        Button(Strings.onboardingLater) { Task { await model.dismissLoginItem() } }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                }
                // ⑤ はボタンを置かない（アプリは改名しない。DEV-10）
                ForEach(items.filter { $0.step == .deviceName }) { item in
                    if let detail = item.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// 「はじめに」の 1 マス（チェックと題）。
private struct OnboardingCell: View {
    let item: OnboardingItem

    var body: some View {
        Label {
            Text(item.title).font(.subheadline).foregroundStyle(item.done ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(item.done ? Color.green : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
