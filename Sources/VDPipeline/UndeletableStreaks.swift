// 観測できた状態で消せなかった評価の連続回数（PLAN §8.9.5 の手順 5a。F-69・F-80）。
// Worker が tick をまたいで 1 つ持つ。メモリだけ（再起動で 0 に戻っても決着が遅れるだけで、消す側には倒れない）。
import Synchronization
import VDCore

/// Part ごとの連続回数。挿し直し（接続の区切りが変わった）で 1 から数え直す。
/// 鍵の照合はスカラー列（00-api-map §0。Swift の String の == は正準等価で比べる）。
final class UndeletableStreaks: Sendable {
    /// 連続を数える接続の区切り（F-69・F-80）: 全体の connectEpoch と、そのデバイスの deviceNode
    /// （マウントし直すと変わりうる。同じノードで挿し直した場合は見分けられない）
    struct Connection: Equatable, Sendable {
        let epoch: UInt64
        let deviceNode: String?
    }

    private struct Streak {
        var session: [Unicode.Scalar]
        var connection: Connection
        var count: Int
        /// 前に数えた観測の時刻（F-80。これから minIntervalSeconds 未満の観測は数えない）
        var lastCountedAt: Instant
    }

    private let streaks = Mutex<[[Unicode.Scalar]: Streak]>([:])

    init() {}

    /// 観測できた失敗を 1 回記録し、連続回数を返す。接続の区切りが前回と違えば 1 から数え直す。
    /// 2 回目以降は、前に数えた観測から minIntervalSeconds 以上たった観測だけを数える（F-80。それより早い観測は回数を据え置き、切りもしない）
    func record(
        _ partkey: String, session: String, connection: Connection, now: Instant, minIntervalSeconds: Int
    ) -> Int {
        let key = Array(partkey.unicodeScalars)
        let sessionScalars = Array(session.unicodeScalars)
        return streaks.withLock { all in
            guard var s = all[key], s.connection == connection else {
                all[key] = Streak(session: sessionScalars, connection: connection, count: 1, lastCountedAt: now)
                return 1
            }
            s.session = sessionScalars
            if now - s.lastCountedAt >= Int64(minIntervalSeconds) * 1000 {
                s.count += 1
                s.lastCountedAt = now
            }
            all[key] = s
            return s.count
        }
    }

    /// 連続を切る（観測できない評価・消せた・決着した）
    func reset(_ partkey: String) {
        _ = streaks.withLock { $0.removeValue(forKey: Array(partkey.unicodeScalars)) }
    }

    /// Session の評価の終わりに、その Session の項目のうち keeping（この評価で観測できた失敗として記録した Part）に無いものを捨てる
    /// （F-80。途中で戻った評価は keeping を空にして全部切る。RAW_SAVED / ID の無い SOURCE_DELETE_PENDING でなくなった Part の項目を残さない）
    func retain(session: String, keeping partkeys: [String]) {
        let sessionScalars = Array(session.unicodeScalars)
        let kept = Set(partkeys.map { Array($0.unicodeScalars) })
        streaks.withLock { all in
            all = all.filter { $0.value.session != sessionScalars || kept.contains($0.key) }
        }
    }

    /// 持っている項目の数（辞書が縮むことをテストが確かめる）
    var count: Int { streaks.withLock { $0.count } }
}
