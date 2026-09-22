// パネルの体裁（PLAN §8.12「幅 380pt、縦スクロール」）。
import SwiftUI

/// パネルの幅・余白・節の間隔。
enum PanelStyle {
    static let width: CGFloat = 380
    static let maxHeight: CGFloat = 640
    static let padding: CGFloat = 14
    static let sectionSpacing: CGFloat = 12
}

/// 節の枠（見出し ＋ 中身）。中身が空なら何も描かない。
struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        if Content.self != EmptyView.self {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                content()
            }
        }
    }
}
