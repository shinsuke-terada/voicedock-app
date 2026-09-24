// 統合済みの segment をチャンクに分ける（voicedock llm.py:700-786 と同じ結果）。時刻は LLM に渡さない。
import Foundation
import VDCore

public struct Chunk: Equatable, Sendable {
    /// segments の行（`Chunker.line`。話者つきは `話者A: ` を前に付ける。F-89）を "\n" でつないだもの。
    public let text: String
    /// segments[0].at。
    public let startAt: Instant
    /// segments の endAt の最大。
    public let endAt: Instant
    public let segments: [AbsoluteSegment]
}

public enum Chunker {
    /// segs は統合済みで (at, endAt) の順。並べ替えない。segment の境界でだけ切る（1 つで上限を超える segment は単独のチャンク）。
    public static func chunk(_ segs: [AbsoluteSegment], maxChars: Int, maxSeconds: Int, overlapChars: Int) -> [Chunk] {
        var chunks: [Chunk] = []
        var current: [AbsoluteSegment] = []
        for seg in segs {
            guard let first = current.first else {
                current = [seg]
                continue
            }
            // 区切りの "\n" は数えない。文字数は Unicode スカラー数。
            let chars = current.reduce(0) { $0 + TextLimit.scalarCount($1.text) } + TextLimit.scalarCount(seg.text)
            let overChars = chars > maxChars
            // ミリ秒の整数で比べる。
            let overTime = (seg.endAt - first.at) > Int64(maxSeconds) * 1000
            if overChars || overTime {
                if let made = make(current) {
                    chunks.append(made)
                }
                // LLM-05: 実時間で超えたら重ねない（両方超えたときも重ねない）。
                current = overTime ? [] : overlap(current, overlapChars)
            }
            current.append(seg)
        }
        if !current.isEmpty && !onlyOverlap(chunks, current), let made = make(current) {
            chunks.append(made)
        }
        return chunks
    }

    /// 末尾から limit スカラーぶんの segment（segment 単位）。全部は重ねない（先頭の 1 つを落とす）。
    private static func overlap(_ current: [AbsoluteSegment], _ limit: Int) -> [AbsoluteSegment] {
        if limit <= 0 {
            return []
        }
        var taken: [AbsoluteSegment] = []
        var total = 0
        for seg in current.reversed() {
            let count = TextLimit.scalarCount(seg.text)
            if total + count > limit && !taken.isEmpty {
                break
            }
            taken.insert(seg, at: 0)
            total += count
        }
        return taken.count < current.count ? taken : Array(taken.dropFirst())
    }

    /// 末尾が直前のチャンクの重なりだけでできているか（重なりだけの末尾チャンクを作らない）。
    private static func onlyOverlap(_ chunks: [Chunk], _ current: [AbsoluteSegment]) -> Bool {
        guard let last = chunks.last else {
            return false
        }
        return current.allSatisfy { seg in last.segments.contains(seg) }
    }

    private static func make(_ segments: [AbsoluteSegment]) -> Chunk? {
        guard let first = segments.first, let endAt = segments.map(\.endAt).max() else {
            return nil
        }
        return Chunk(
            text: segments.map(Self.line).joined(separator: "\n"), startAt: first.at, endAt: endAt, segments: segments)
    }

    /// 話者つきの区間は `話者A: <text>`（PLAN §8.5。F-89）。話者なしは text のまま。
    static func line(_ seg: AbsoluteSegment) -> String {
        guard let speaker = seg.speaker else { return seg.text }
        return SpeakerLabel.display(speaker) + ": " + seg.text
    }
}
