// 後追いの結果の 1 行（PLAN §8.9.9。F-72・issue #112 の G1）。飛ばした数はプレビューの件数との差、増えた分は実行していないと添える。
import Testing
import VDPipeline

@testable import VoiceDockApp

@Suite("BacklogTexts（F-72 結果の 1 行）")
struct BacklogTextsConsentTests {
    static let addedNote = "もう一度押してプレビューから確かめてください"

    @Test(
        "F-72 結果の 1 行はプレビューの件数と増えた件数を出す（パラメータ化）",
        arguments: [
            (
                BacklogKind.backlog, 1, 2, 1,
                "1 件の削除要求を書きました。プレビューの後に増えた 2 件は実行していません（" + addedNote + "）"
            ),
            (
                BacklogKind.resolveAbsent, 2, 1, 1,
                "1 件を完了にしました（1 件は状態が変わったため飛ばしました）。プレビューの後に増えた 1 件は実行していません（" + addedNote + "）"
            ),
            (BacklogKind.backlog, 3, 0, 1, "1 件の削除要求を書きました（2 件は状態が変わったため飛ばしました）"),
        ])
    func resultLineShowsThePreviewScope(
        _ kind: BacklogKind, _ previewed: Int, _ added: Int, _ done: Int, _ expected: String
    ) {
        let execution = BacklogExecution(previewed: previewed, added: added, done: done)
        #expect(BacklogTexts.resultLine(kind, execution) == expected)
    }

    @Test("F-72 プレビューも実行も 0 件なら 0 件とだけ出す（TEST-28）")
    func emptyExecution() {
        let execution = BacklogExecution(previewed: 0, added: 0, done: 0)
        #expect(BacklogTexts.resultLine(.backlog, execution) == "0 件の削除要求を書きました")
        #expect(BacklogTexts.resultLine(.resolveAbsent, execution) == "0 件を完了にしました")
    }
}
