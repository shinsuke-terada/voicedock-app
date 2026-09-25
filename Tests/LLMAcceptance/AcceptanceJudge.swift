// LLM 受け入れ試験の判定の式（純関数。PLAN §10.6 の 1〜4。T-24 §4.5）。
import Foundation
import VDCore
import VDLLM

/// 判定の結果。
struct AcceptanceVerdict: Equatable, Sendable {
    /// .success の本数。
    let analyzed: Int
    let total: Int
    let calls: Int
    let repairFreeCalls: Int
    /// calls == 0 なら 0.0。
    let repairFreeRate: Double
    /// 最終的に通った本体の要求の割合（calls == 0 なら 0.0）。
    let repairedRate: Double
    /// "[[" を含んだ (fixture, 場所)。
    let wikiLinkHits: [String]
    /// due の形が不正、または maxTasksWithDue を超えた fixture。
    let badDue: [String]
    /// 長文の所要秒。長文の結果が無ければ +∞（J4 を落とす）。
    let longSeconds: Double

    /// J1〜J4 がすべて真。
    var passed: Bool { j1 && j2 && j3 && j4 }
    /// J1: 10 本すべてが .success。
    var j1: Bool { analyzed == total }
    /// J2: 修復なしで 90% 以上、かつ修復込みで 100%。
    var j2: Bool { repairFreeRate >= AcceptanceJudge.repairFreeThreshold && repairedRate == 1.0 }
    /// J3: 出力に "[[" が無く、due が正しい。
    var j3: Bool { wikiLinkHits.isEmpty && badDue.isEmpty }
    /// J4: 長文が 30 分以内。
    var j4: Bool { longSeconds <= AcceptanceJudge.longLimitSeconds }
}

enum AcceptanceJudge {
    static let repairFreeThreshold = 0.90
    /// 30 分（PLAN §10.6 の 4）。
    static let longLimitSeconds: Double = 1_800
    static let duePattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"
    /// wikiLinkHits に入れる先頭のスカラー数。
    static let hitPrefixScalars = 40

    static func judge(_ runs: [AcceptanceRun], longID: String) -> AcceptanceVerdict {
        var analyzed = 0
        var calls = 0
        var repairedCalls = 0
        var validated = 0
        var hits: [String] = []
        var badDue: [String] = []
        for run in runs {
            calls += run.calls
            repairedCalls += run.repairedCalls
            switch run.outcome {
            case .failure:
                // 最後の本体の要求が落ちて終わった（Analyzer は最初の失敗で止まる）
                validated += max(0, run.calls - 1)
            case .success(let result, let partials, _, _):
                analyzed += 1
                validated += run.calls
                for text in strings(result) + partials.flatMap(strings) where containsScalars(text, "[[") {
                    hits.append("\(run.fixtureID): \(TextLimit.prefix(text, scalars: hitPrefixScalars))")
                }
                let dues = (result.tasks ?? []).compactMap(\.due)
                if dues.contains(where: { !matchesDuePattern($0) }) || dues.count > run.maxTasksWithDue {
                    badDue.append(run.fixtureID)
                }
            }
        }
        let long = runs.first { $0.fixtureID == longID }.map { seconds($0.elapsed) } ?? .infinity
        return AcceptanceVerdict(
            analyzed: analyzed, total: runs.count, calls: calls, repairFreeCalls: calls - repairedCalls,
            repairFreeRate: calls == 0 ? 0.0 : Double(calls - repairedCalls) / Double(calls),
            repairedRate: calls == 0 ? 0.0 : Double(validated) / Double(calls),
            wikiLinkHits: hits, badDue: badDue, longSeconds: long)
    }

    /// AnalysisResult の全文字列（title・summary・各配列の要素・tasks の text と due）。
    static func strings(_ r: AnalysisResult) -> [String] {
        var all: [String] = []
        all += [r.title, r.summary].compactMap { $0 }
        all += r.keyPoints ?? []
        for task in r.tasks ?? [] {
            all.append(task.text)
            if let due = task.due { all.append(due) }
        }
        all += r.decisions ?? []
        all += r.ideas ?? []
        all += r.tags ?? []
        return all
    }

    /// Duration を秒にする。
    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// duePattern に一致するか。
    static func matchesDuePattern(_ due: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: duePattern) else { return false }
        let range = NSRange(due.startIndex..., in: due)
        return regex.firstMatch(in: due, range: range) != nil
    }

    /// スカラー列として needle を含むか。
    static func containsScalars(_ text: String, _ needle: String) -> Bool {
        let hay = Array(text.unicodeScalars)
        let pin = Array(needle.unicodeScalars)
        guard !pin.isEmpty, hay.count >= pin.count else { return pin.isEmpty }
        return (0...(hay.count - pin.count)).contains { start in hay[start..<(start + pin.count)].elementsEqual(pin) }
    }
}
