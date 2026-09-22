// 観測できた状態で消せなかった評価の連続回数（PLAN §8.9.5 の手順 5a。F-69）。
// Worker が tick をまたいで 1 つ持つ。メモリだけ（再起動で 0 に戻っても決着が遅れるだけで、消す側には倒れない）。
import Synchronization

/// Part ごとの連続回数。挿し直し（connectEpoch が変わった）で 1 から数え直す。
final class UndeletableStreaks: Sendable {
    private struct Streak {
        var connectEpoch: UInt64
        var count: Int
    }

    private let streaks = Mutex<[String: Streak]>([:])

    init() {}

    /// 観測できた失敗を 1 回数え、新しい連続回数を返す（connectEpoch が前回と違えば 1）
    func record(_ partkey: String, connectEpoch: UInt64) -> Int {
        streaks.withLock { all in
            var s = all[partkey] ?? Streak(connectEpoch: connectEpoch, count: 0)
            if s.connectEpoch != connectEpoch { s = Streak(connectEpoch: connectEpoch, count: 0) }
            s.count += 1
            all[partkey] = s
            return s.count
        }
    }

    /// 連続を切る（観測できない評価・消せた・決着した）
    func reset(_ partkey: String) {
        _ = streaks.withLock { $0.removeValue(forKey: partkey) }
    }
}
