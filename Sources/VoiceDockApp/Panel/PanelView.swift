// パネル本体（PLAN §8.12 の 1〜9 をこの順に）。主画面はスクロールしない。長い中身は popover の中の別の画面へ（F-65）。
import SwiftUI

/// パネル本体。主画面は内容に合わせた高さで、ScrollView を持たない（PanelLayoutPolicyTests が固定する）。
/// 節の順を変えない（PLAN §8.12 の番号がそのまま並び。7・8 は別の画面への行、6 は「はじめに」か ⚙ の画面）。
struct PanelView: View {
    /// 参照は @Observable なので let でもよいが、後続が binding を使う
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch model.screen {
            case .main:
                main
            case .attention:
                SubScreen(title: Strings.sectionAttention, model: model) {
                    AttentionSection(model: model, limit: nil)
                }
            case .deletion:
                SubScreen(title: Strings.sectionDeletion, model: model) { DeletionSection(model: model) }
            case .details:
                SubScreen(title: Strings.rowDetails, model: model) { DetailsSection(model: model) }
            case .settings:
                SubScreen(title: Strings.screenSettings, model: model) {
                    SectionBox(title: Strings.sectionGeneral) { GeneralSection(model: model) }
                    Text(model.versionLine).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(PanelStyle.padding)
        .frame(width: PanelStyle.width, alignment: .topLeading)
        // 高さは中身に合わせる（StatusItemController が preferredContentSize で popover に伝える）
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 主画面（スクロールしない）
    private var main: some View {
        VStack(alignment: .leading, spacing: PanelStyle.sectionSpacing) {
            StatusSection(model: model)  // 1
            AttentionSection(model: model)  // 2  T-32（先頭の 2 件）
            OnboardingSection(model: model)  // 3  T-31（6 のトグルもここ。完了後は ⚙ の画面）
            VaultSection(model: model)  // 4  T-31
            ModelsSection(model: model)  // 5  T-31
            if DeletionSection.isAvailable(model) {
                PanelRow(
                    systemImage: model.showsTrash ? "trash.fill" : "trash",
                    tint: model.showsTrash ? .red : .secondary,
                    title: Strings.rowDeletion,
                    value: model.showsTrash ? Strings.deletionOn : Strings.deletionOff
                ) { Task { await model.show(.deletion) } }  // 7  T-40
            }
            PanelRow(systemImage: "stethoscope", title: Strings.rowDetails) {
                Task { await model.show(.details) }
            }  // 8  T-32
            Button(Strings.buttonQuit) { model.quit() }  // 9
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }
}
