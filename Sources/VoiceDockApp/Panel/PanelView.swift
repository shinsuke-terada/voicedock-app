// パネル本体（PLAN §8.12 の 1〜9 をこの順に）。
import SwiftUI

/// パネル本体。節の順を変えない（PLAN §8.12 の番号がそのまま並び）。
struct PanelView: View {
    /// 参照は @Observable なので let でもよいが、後続が binding を使う
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PanelStyle.sectionSpacing) {
                StatusSection(model: model)  // 1
                AttentionSection(model: model)  // 2  T-32
                OnboardingSection(model: model)  // 3  T-31
                VaultSection(model: model)  // 4  T-31
                ModelsSection(model: model)  // 5  T-31
                GeneralSection(model: model)  // 6  T-31
                DeletionSection(model: model)  // 7  T-40
                DetailsSection(model: model)  // 8  T-32
                Divider()
                Button(Strings.buttonQuit) { model.quit() }  // 9
            }
            .padding(PanelStyle.padding)
            .frame(width: PanelStyle.width, alignment: .leading)
        }
        // ScrollView は自分の高さを持たないので、高さを固定する（maxHeight だけだと popover が 1pt に潰れる）
        .frame(width: PanelStyle.width, height: PanelStyle.maxHeight)
    }
}
