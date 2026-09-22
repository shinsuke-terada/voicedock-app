// パネルの中の画面の切り替え（PLAN §8.12。F-65）。「詳細・診断」の画面にいる間だけ状態の詳細を読む。
import Foundation

extension AppModel {
    /// 画面を切り替える。「詳細・診断」に入ったら状態の詳細を読み、出たら捨てる（閉じている間は inbox も staging も走査しない）
    func show(_ next: PanelScreen) async {
        screen = next
        if next == .details {
            if !detailsExpanded { await toggleDetails() }
        } else if detailsExpanded {
            await toggleDetails()
        }
    }
}
