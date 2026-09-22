// 「はじめに」の節（PLAN §8.12 の 3）。
import SwiftUI

/// 「はじめに」の節。未完了で見える項目が 1 つも無ければ何も出さない。
struct OnboardingSection: View {
    let model: AppModel

    var body: some View {
        let items = OnboardingEvaluator.items(model.snapshot)
        if items.contains(where: { $0.visible && !$0.done }) {
            SectionBox(title: Strings.sectionOnboarding) {
                ForEach(items.filter(\.visible)) { item in
                    OnboardingRow(model: model, item: item)
                }
            }
        } else {
            EmptyView()
        }
    }
}

/// 「はじめに」の 1 行。
private struct OnboardingRow: View {
    let model: AppModel
    let item: OnboardingItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                Text(item.title)
                if item.step == .loginItem && !item.done {
                    Spacer()
                    Button(Strings.onboardingLater) { Task { await model.dismissLoginItem() } }
                }
            }
            // ⑤ はボタンを置かない（アプリは改名しない。DEV-10）
            if let detail = item.detail {
                Text(detail).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
