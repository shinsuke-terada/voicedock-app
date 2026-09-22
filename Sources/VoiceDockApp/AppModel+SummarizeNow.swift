// 今すぐ要約（PLAN §5.4・§8.12 の 1。F-66）。Worker の直列ループに 1 件の仕事として入れ、返事を短い通知にする。
import Foundation
import VDPipeline

extension AppModel {
    /// 今すぐ要約の表示の状態（F-66）
    enum SummarizeNowState: Equatable {
        case idle
        /// 返事を待っている（ボタンを押せない）
        case running
        /// 閉じた Session の数（0 = 未要約の録音が無い）
        case succeeded(Int)
        /// 行わなかった理由（SummarizeNowFailure.message のまま）
        case failed(String)
    }

    /// 通知を出しておく目安の秒数（ビューがこの秒数の後に dismissSummarizeNowNotice を呼ぶ）
    static let summarizeNowNoticeSeconds = 4

    /// 状態の見出しに出す短い通知（nil = 出さない）
    var summarizeNowNotice: String? {
        switch summarizeNow {
        case .idle, .running: nil
        case .succeeded(let n): n > 0 ? Strings.summarizeNowStarted(n) : Strings.summarizeNowNothing
        case .failed(let message): message
        }
    }

    /// 「今すぐ要約」。Worker の直列ループに `.summarizeNow` を 1 件入れる（PLAN §5.4）。実行中は二重に押せない
    func requestSummarizeNow() async {
        guard summarizeNow != .running else { return }
        summarizeNow = .running
        summarizeNowGeneration += 1
        let generation = summarizeNowGeneration
        // reply は Worker の文脈で呼ばれるので MainActor へ移してから状態を変える
        await services.enqueue(
            .summarizeNow(reply: { [weak self] r in
                Task { @MainActor in self?.receiveSummarizeNow(r, generation: generation) }
            }))
    }

    /// 今すぐ要約の返事（閉じた後の返事・前の世代の返事は捨てる）
    func receiveSummarizeNow(_ r: Result<Int, SummarizeNowFailure>, generation: Int) {
        guard summarizeNow == .running, generation == summarizeNowGeneration else { return }
        switch r {
        case .success(let n): summarizeNow = .succeeded(n)
        case .failure(let f): summarizeNow = .failed(f.message)
        }
    }

    /// 通知を消す（出したときの状態のままなら。消すまでの間に押し直していれば何もしない）
    func dismissSummarizeNowNotice(_ shown: SummarizeNowState) {
        guard shown != .idle, shown != .running, summarizeNow == shown else { return }
        summarizeNow = .idle
    }
}
