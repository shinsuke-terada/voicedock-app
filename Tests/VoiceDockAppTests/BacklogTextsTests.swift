// 後追いの文言と整形（PLAN §8.9.9。T-41 §6.3）。期待はすべて T-41 §4.3 から手で書く。
import Testing
import VDPipeline

@testable import VoiceDockApp

@Suite("BacklogTexts")
struct BacklogTextsTests {
    static func skips(_ pairs: [(String, String)]) -> [BacklogSkip] {
        pairs.map { BacklogSkip(partkey: $0.0, reason: $0.1) }
    }

    @Test("過去分のプレビュー")
    func backlogPreviewLines() {
        let plan = BacklogPlan(
            eligible: ["a", "b"],
            skipped: Self.skips([("c", "not_deletable"), ("d", "already_deleted"), ("e", "not_deletable")]))
        #expect(
            BacklogTexts.previewLines(.backlog, plan) == [
                "削除要求を書く対象: 2 件", "対象外: 3 件", "・削除済み: 1 件", "・削除の条件を満たさない: 2 件",
            ])
    }

    @Test("手動で消した分のプレビュー（注記つき）")
    func resolveAbsentPreviewLines() {
        let plan = BacklogPlan(eligible: ["a"], skipped: Self.skips([("b", "device_absent"), ("c", "still_present")]))
        #expect(
            BacklogTexts.previewLines(.resolveAbsent, plan) == [
                "完了にする対象: 1 件", "対象外: 2 件", "・デバイスが未接続か観測が古い: 1 件", "・デバイスにまだ在る: 1 件",
                "デバイスに無いことを確かめた録音だけを完了にします（削除した記録は付けません）",
            ])
    }

    @Test("対象 0 件（TEST-28）")
    func emptyPreview() {
        #expect(
            BacklogTexts.previewLines(.backlog, BacklogPlan(eligible: [], skipped: [])) == [
                "削除要求を書く対象: 0 件", "対象はありません",
            ])
    }

    @Test("表に無い理由はそのまま最後に")
    func unknownReasonIsShownAsIs() {
        let plan = BacklogPlan(eligible: [], skipped: Self.skips([("a", "weird")]))
        #expect(
            BacklogTexts.previewLines(.backlog, plan) == [
                "削除要求を書く対象: 0 件", "対象はありません", "対象外: 1 件", "・weird: 1 件",
            ])
    }

    @Test(
        "結果の 1 行（パラメータ化）",
        arguments: [
            (BacklogKind.backlog, 2, 2, "2 件の削除要求を書きました"),
            (BacklogKind.backlog, 1, 3, "1 件の削除要求を書きました（2 件は状態が変わったため飛ばしました）"),
            (BacklogKind.resolveAbsent, 1, 1, "1 件を完了にしました"),
        ])
    func resultLines(_ kind: BacklogKind, _ done: Int, _ planned: Int, _ expected: String) {
        let execution = BacklogExecution(previewed: planned, added: 0, done: done)
        #expect(BacklogTexts.resultLine(kind, execution) == expected)
    }

    @Test("ボタンの文言")
    func titles() {
        #expect(BacklogTexts.buttonTitle(.backlog) == "過去分を削除対象にする")
        #expect(BacklogTexts.buttonTitle(.resolveAbsent) == "手動で消した分を完了にする")
        #expect(BacklogTexts.executeTitle(.backlog, count: 3) == "削除要求を書く（3 件）")
        #expect(BacklogTexts.executeTitle(.resolveAbsent, count: 1) == "完了にする（1 件）")
        #expect(BacklogTexts.failureLine("x") == "実行できませんでした: x")
    }
}
