// whisper の区間に話者を付ける（PLAN §8.4.1）。
import Foundation
import VDCore

public enum SpeakerAssigner {
    /// 重なりが無いとき、この秒数以内の最も近い区間の話者を付ける。
    public static let nearestToleranceSeconds = 1.0

    /// 各区間に話者を付け、区間の順に初めて出た順で SpeakerLabel.label に付け替える。区間の数と順・start・end・text は変えない。
    public static func assign(_ segments: [TranscriptSegment], turns: [SpeakerTurn]) -> [TranscriptSegment] {
        // 1. RTTM の話者の順位 = turns の中で初めて出た位置（同点の決め手）
        var rank: [String: Int] = [:]
        for turn in turns where rank[turn.speaker] == nil {
            rank[turn.speaker] = rank.count
        }
        // 3. RTTM の話者名 → ラベル（区間の順に初めて出た順。区間に付かなかった話者はラベルを消費しない）
        var labels: [String: String] = [:]
        return segments.map { segment in
            guard let name = speaker(for: segment, turns: turns, rank: rank) else {
                return TranscriptSegment(start: segment.start, end: segment.end, text: segment.text, speaker: nil)
            }
            let label: String
            if let known = labels[name] {
                label = known
            } else {
                label = SpeakerLabel.label(index: labels.count)
                labels[name] = label
            }
            return TranscriptSegment(start: segment.start, end: segment.end, text: segment.text, speaker: label)
        }
    }

    /// 2. 区間 1 つの RTTM の話者名。重なりの最大（同点は順位の小さい話者）、無ければ許容内の最も近い行（同点は先の行）。
    private static func speaker(for s: TranscriptSegment, turns: [SpeakerTurn], rank: [String: Int]) -> String? {
        var overlap: [String: Double] = [:]
        for t in turns {
            overlap[t.speaker, default: 0] += max(0, min(s.end, t.end) - max(s.start, t.start))
        }
        var best: (name: String, total: Double, rank: Int)?
        for (name, total) in overlap where total > 0 {
            let r = rank[name] ?? Int.max
            if let b = best, total < b.total || (total == b.total && r > b.rank) { continue }
            best = (name, total, r)
        }
        if let best { return best.name }

        var nearest: (name: String, gap: Double)?
        for t in turns {
            let gap = max(t.start - s.end, s.start - t.end, 0)
            guard gap <= nearestToleranceSeconds else { continue }
            if let n = nearest, gap >= n.gap { continue }
            nearest = (t.speaker, gap)
        }
        return nearest?.name
    }
}
