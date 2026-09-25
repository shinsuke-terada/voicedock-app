// popover の中の別の画面の枠（PLAN §8.12。F-65）。見出しに「‹ 戻る」。中身が長いときだけ、この画面の中でスクロールする。
import SwiftUI

/// 別の画面の枠。見出し（「‹ 戻る」と題）と中身。中身の高さが `PanelStyle.maxScreenHeight` を超えたときだけスクロールする。
/// ScrollView は自分の高さを持たないので、中身の高さを測って枠の高さを決める（popover が潰れないように。PR #100）。
struct SubScreen<Content: View>: View {
    let title: String
    let model: AppModel
    let content: Content

    /// 測る前は上限の高さ（0 から始めると、測るまでの一瞬 popover が潰れる）
    @State private var contentHeight: CGFloat = PanelStyle.maxScreenHeight

    init(title: String, model: AppModel, @ViewBuilder content: () -> Content) {
        self.title = title
        self.model = model
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PanelStyle.sectionSpacing) {
            ZStack {
                Text(title).font(.headline)
                HStack {
                    Button {
                        Task { await model.show(.main) }
                    } label: {
                        Label(Strings.buttonBack, systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: PanelStyle.sectionSpacing) {
                    content
                }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    contentHeight = $0
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(contentHeight, 1), PanelStyle.maxScreenHeight))
        }
    }
}
