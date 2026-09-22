// 「要対応」の節（PLAN §8.12 の 2）。利用者の操作が要るものだけを出す（OPS-12）。
import SwiftUI
import VDPipeline

/// 「要対応」の節。空なら何も出さない。1 項目 1 ブロック（題・説明・操作ボタン）。
struct AttentionSection: View {
    let model: AppModel

    var body: some View {
        if model.snapshot.attention.isEmpty {
            EmptyView()
        } else {
            SectionBox(title: Strings.sectionAttention) {
                ForEach(Array(model.snapshot.attention.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AttentionTexts.title(item)).bold()
                        Text(
                            AttentionTexts.detail(
                                item, path: model.snapshot.vaultPath ?? "", marker: model.snapshot.vaultMarker)
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(item.actions.enumerated()), id: \.offset) { _, action in
                            Button(AttentionTexts.button(action)) { model.perform(action) }
                        }
                    }
                }
            }
        }
    }
}
