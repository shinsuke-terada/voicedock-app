// 「要対応」のカード（PLAN §8.12 の 2）。利用者の操作が要るものだけを出す（OPS-12）。多いときは主画面に先頭の 2 件（F-65）。
import SwiftUI
import VDPipeline

/// 「要対応」のカード。空なら何も出さない。1 項目 1 ブロック（題・説明・操作ボタン）。
/// 主画面（`limit` あり）では先頭の `limit` 件と「ほか n 件 ›」、要対応の画面（`limit` が nil）では全件。
struct AttentionSection: View {
    let model: AppModel
    var limit: Int? = AttentionSection.mainLimit

    /// 主画面に出す件数（PLAN §8.12 の 2）
    static let mainLimit = 2

    /// 出す項目と、出さずに「ほか n 件」にまとめる件数
    static func split(_ items: [AttentionItem], limit: Int?) -> (shown: [AttentionItem], rest: Int) {
        guard let limit, items.count > limit else { return (items, 0) }
        return (Array(items.prefix(max(limit, 0))), items.count - max(limit, 0))
    }

    var body: some View {
        let items = model.snapshot.attention
        if !items.isEmpty {
            let (shown, rest) = Self.split(items, limit: limit)
            SectionBox(title: Strings.sectionAttention) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                    AttentionBlock(model: model, item: item)
                }
                if rest > 0 {
                    Button {
                        Task { await model.show(.attention) }
                    } label: {
                        HStack(spacing: 4) {
                            Text(Strings.attentionMore(rest))
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: PanelStyle.cornerRadius, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
            )
        }
    }
}

/// 要対応の 1 項目（題・説明・操作ボタン）。
private struct AttentionBlock: View {
    let model: AppModel
    let item: AttentionItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(AttentionTexts.title(item)).font(.subheadline.weight(.semibold))
                Text(
                    AttentionTexts.detail(
                        item, path: model.snapshot.vaultPath ?? "", marker: model.snapshot.vaultMarker)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if !item.actions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(item.actions.enumerated()), id: \.offset) { _, action in
                            Button(AttentionTexts.button(action)) { model.perform(action) }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }
}
