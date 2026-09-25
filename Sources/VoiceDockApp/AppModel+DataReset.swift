// 「詳細・診断」のデータの初期化（PLAN §8.12 の 8・F-95）。予約して終了し、次の起動で DB を開く前に消す。
import Foundation

extension AppModel {
    /// 元音声の削除が有効か、消す能力が残っているか（初期化を押せない理由。LiveServices.requestDataReset と同じ 2 つ）
    var dataResetBlockedByDeletion: Bool { showsTrash || snapshot.deletionResidual }

    /// 初期化の長押しを押せるか: 元音声の削除が有効でも消す能力が残ってもいない間で、予約の実行中でない
    var canRequestDataReset: Bool { !dataResetBlockedByDeletion && !dataResetBusy }

    /// 「初期化して終了」。赤いボタンの長押しが完了したときだけ呼ぶ（HoldToConfirmButton）。
    /// 予約できたら終了する（初期化は次の起動で行う）。元音声の削除が有効な間は何もしない（services も確かめ直す）
    func requestDataReset() async {
        guard canRequestDataReset else { return }
        dataResetBusy = true
        defer { dataResetBusy = false }
        dataResetFailed = false
        if await services.requestDataReset() {
            quit()
        } else {
            dataResetFailed = true
        }
    }
}
