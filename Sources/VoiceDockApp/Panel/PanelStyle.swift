// パネルの体裁（PLAN §8.12「幅 380pt 前後、カード型。主画面はスクロールしない」。F-65）。
import SwiftUI

/// パネルの幅・余白・カードの体裁・状態の色。
enum PanelStyle {
    static let width: CGFloat = 380
    /// 別の画面の中身の高さの上限（これを超えたときだけ、その画面の中でスクロールする）
    static let maxScreenHeight: CGFloat = 560
    static let padding: CGFloat = 12
    static let sectionSpacing: CGFloat = 10
    static let cardPadding: CGFloat = 12
    static let cardSpacing: CGFloat = 8
    static let cornerRadius: CGFloat = 10

    /// 状態の見出しの記号（メニューバーの記号の塗りつぶし版）
    static func headerSymbol(_ state: IconState) -> String {
        switch state {
        case .idle: "waveform.circle.fill"
        case .ingesting: "arrow.down.circle.fill"
        case .processing: "text.bubble.fill"
        case .attention: "exclamationmark.triangle.fill"
        }
    }

    /// 要対応の操作で目立たせるカードの枠（「モデルの節を開く」「有効化フローを開く」。F-65・F-84）
    static let highlightOpacity: Double = 0.6

    /// 状態の見出しの色（待機＝緑、取り込み・処理中＝青、要対応＝橙）
    static func tint(_ state: IconState) -> Color {
        switch state {
        case .idle: .green
        case .ingesting, .processing: .blue
        case .attention: .orange
        }
    }
}

/// カード（見出し ＋ 右肩の小さな文字 ＋ 中身）。角丸の薄い背景で、余白は均一。
struct SectionBox<Content: View>: View {
    let title: String?
    let trailing: String?
    let content: Content

    init(title: String? = nil, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PanelStyle.cardSpacing) {
            if title != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let trailing {
                        Text(trailing).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            content
        }
        .padding(PanelStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PanelStyle.cornerRadius, style: .continuous).fill(.quaternary.opacity(0.5))
        )
    }
}

extension View {
    /// 要対応の操作で開いたカードに橙の枠を付ける（on が偽なら透明。枠の有無で大きさを変えない。F-65・F-84）
    func attentionHighlight(_ on: Bool) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: PanelStyle.cornerRadius, style: .continuous)
                .strokeBorder(Color.orange.opacity(on ? PanelStyle.highlightOpacity : 0), lineWidth: 1)
        )
    }
}
