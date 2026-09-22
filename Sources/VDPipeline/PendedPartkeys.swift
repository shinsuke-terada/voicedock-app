// この tick で PENDING に落とした（delete_request_id を外した）Part（PLAN §8.9.5 DEL-11: 同じ周回で再要求しない）。
// TickContext が 1 tick に 1 つ持つ（tick ごとに新しくなる）。
import Synchronization

/// この tick で PENDING に落とした Part の集合（DEL-11）。
final class PendedPartkeys: Sendable {
    private let keys = Mutex<Set<String>>([])

    init() {}

    func insert(_ partkey: String) {
        _ = keys.withLock { $0.insert(partkey) }
    }

    func contains(_ partkey: String) -> Bool {
        keys.withLock { $0.contains(partkey) }
    }
}
