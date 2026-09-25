// 「詳細・診断」のデータの初期化（PLAN §8.12 の 8・F-95）。予約して終了し、次の起動で DB を開く前に消す。
import Foundation
import VDPipeline

extension AppModel {
    /// 元音声の削除が有効か、消す能力が残っているか（初期化を押せない理由。LiveServices.requestDataReset と同じ 2 つ）
    var dataResetBlockedByDeletion: Bool { showsTrash || snapshot.deletionResidual }

    /// 初期化の長押しを押せるか: 元音声の削除が有効でも消す能力が残ってもいない間で、予約の実行中・終了の待ちでない
    var canRequestDataReset: Bool { !dataResetBlockedByDeletion && !dataResetBusy }

    /// 「初期化して終了」。赤いボタンの長押しが完了したときだけ呼ぶ（HoldToConfirmButton）。
    /// 予約できたら終了する（初期化は次の起動で行う）。元音声の削除が有効な間は何もしない（services も確かめ直す）。
    /// 予約できたら dataResetBusy を戻さない: 終了は run loop の次の周回で始まり後始末に最大 10 秒かかるので、その間に
    /// もう一度押されて終了を重ねない（2 度目の terminate は後始末を飛ばして直ちに終わる。F-76・レビューの #1）
    func requestDataReset() async {
        guard canRequestDataReset else { return }
        dataResetBusy = true
        dataResetFailed = false
        if await services.requestDataReset() {
            quit()
        } else {
            dataResetFailed = true
            dataResetBusy = false
        }
    }

    /// 起動時の初期化の結果（状態の見出しの下に出す。閉じるまで。F-95・レビューの #4）。予約が無ければ nil
    var dataResetNotice: String? {
        dataResetNoticeDismissed ? nil : Strings.dataResetOutcome(snapshot.dataReset)
    }

    /// 結果が注意（消せなかったもの・初期化しなかった）か
    var dataResetNoticeIsWarning: Bool {
        if case .completed(_, 0) = snapshot.dataReset { return false }
        return true
    }
}
