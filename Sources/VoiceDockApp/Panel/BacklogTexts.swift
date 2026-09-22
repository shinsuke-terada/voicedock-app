// 後追いの 2 つのボタンの文言と整形（PLAN §8.9.9）。
import VDPipeline

/// 後追いの 2 つのボタンの文言と整形。文言は逐語。
enum BacklogTexts {
    static let working = "対象を調べています…"
    static let executing = "実行しています…"
    static let cancel = "やめる"
    static let close = "閉じる"
    static let nothing = "対象はありません"
    static let resolveAbsentNote = "デバイスに無いことを確かめた録音だけを完了にします（削除した記録は付けません）"
    /// 対象外の理由の並び（この順に出す）
    static let reasonOrder = [
        DeletionReason.alreadyDeleted, DeletionReason.notDeletable, DeletionReason.deviceAbsent,
        DeletionReason.stillPresent,
    ]

    static func buttonTitle(_ kind: BacklogKind) -> String {
        switch kind {
        case .backlog: return "過去分を削除対象にする"
        case .resolveAbsent: return "手動で消した分を完了にする"
        }
    }

    /// キーは DeletionReason の定数（語を再掲しない。CR-06）。表に無い語はそのまま
    static func reasonLabel(_ reason: String) -> String {
        switch reason {
        case DeletionReason.alreadyDeleted: return "削除済み"
        case DeletionReason.notDeletable: return "削除の条件を満たさない"
        case DeletionReason.deviceAbsent: return "デバイスが未接続か観測が古い"
        case DeletionReason.stillPresent: return "デバイスにまだ在る"
        default: return reason
        }
    }

    static func previewLines(_ kind: BacklogKind, _ plan: BacklogPlan) -> [String] {
        let n = plan.eligible.count
        let m = plan.skipped.count
        var lines: [String] = []
        switch kind {
        case .backlog: lines.append("削除要求を書く対象: " + String(n) + " 件")
        case .resolveAbsent: lines.append("完了にする対象: " + String(n) + " 件")
        }
        if n == 0 { lines.append(nothing) }
        if m > 0 {
            lines.append("対象外: " + String(m) + " 件")
            var counts: [String: Int] = [:]
            var others: [String] = []
            for skip in plan.skipped {
                if counts[skip.reason] == nil && !reasonOrder.contains(skip.reason) { others.append(skip.reason) }
                counts[skip.reason, default: 0] += 1
            }
            for reason in reasonOrder + others {
                guard let count = counts[reason], count >= 1 else { continue }
                lines.append("・" + reasonLabel(reason) + ": " + String(count) + " 件")
            }
        }
        if kind == .resolveAbsent && n > 0 { lines.append(resolveAbsentNote) }
        return lines
    }

    static func executeTitle(_ kind: BacklogKind, count: Int) -> String {
        switch kind {
        case .backlog: return "削除要求を書く（" + String(count) + " 件）"
        case .resolveAbsent: return "完了にする（" + String(count) + " 件）"
        }
    }

    static func resultLine(_ kind: BacklogKind, _ execution: BacklogExecution) -> String {
        var line: String
        switch kind {
        case .backlog: line = String(execution.done) + " 件の削除要求を書きました"
        case .resolveAbsent: line = String(execution.done) + " 件を完了にしました"
        }
        if execution.done < execution.plan.eligible.count {
            line += "（" + String(execution.plan.eligible.count - execution.done) + " 件は状態が変わったため飛ばしました）"
        }
        return line
    }

    static func failureLine(_ message: String) -> String {
        "実行できませんでした: " + message
    }
}
