// 診断と状態の詳細のための読み取り専用の経路。DB ファイルを作らない（CONC-06）。
import Foundation
import GRDB
import VDCore

public final class ReadOnlyStore: Sendable {
    let queue: DatabaseQueue

    private init(queue: DatabaseQueue) {
        self.queue = queue
    }

    /// ファイルが無ければ開こうとせずに nil（SQLite の既定の開き方はファイルを作るため。CONC-06）
    public static func open(url: URL) -> ReadOnlyStore? {
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(10)
        config.label = "VoiceDock.readonly"
        guard let queue = try? DatabaseQueue(path: path, configuration: config) else { return nil }
        return ReadOnlyStore(queue: queue)
    }

    /// 全状態を 0 で埋めた辞書に上書きする。未知の status の行は数えない
    public func statusCounts() throws -> (parts: [PartStatus: Int], sessions: [SessionStatus: Int]) {
        try queue.read { db in
            var parts = Dictionary(uniqueKeysWithValues: PartStatus.allCases.map { ($0, 0) })
            var sessions = Dictionary(uniqueKeysWithValues: SessionStatus.allCases.map { ($0, 0) })
            for row in try Row.fetchAll(db, sql: "SELECT status, COUNT(*) AS n FROM recordings GROUP BY status") {
                let status = try row.decode(String?.self, forColumn: "status")
                if let state = status.flatMap(PartStatus.init(rawValue:)) {
                    parts[state] = try row.decode(Int.self, forColumn: "n")
                }
            }
            for row in try Row.fetchAll(db, sql: "SELECT status, COUNT(*) AS n FROM sessions GROUP BY status") {
                let status = try row.decode(String?.self, forColumn: "status")
                if let state = status.flatMap(SessionStatus.init(rawValue:)) {
                    sessions[state] = try row.decode(Int.self, forColumn: "n")
                }
            }
            return (parts, sessions)
        }
    }

    /// 非終端の件数・長さの合計・長さ不明の件数（FAILED は終端なので入らない。voicedock status.py:326-348）
    public func backlog() throws -> (count: Int, seconds: Double, unknownDuration: Int) {
        let values = PartStatus.allCases.filter { !PartStates.terminal.contains($0) }.map(\.rawValue)
        return try queue.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) AS parts, COALESCE(SUM(duration_seconds), 0) AS seconds, "
                        + "COALESCE(SUM(CASE WHEN duration_seconds IS NULL THEN 1 ELSE 0 END), 0) AS unknown_parts "
                        + "FROM recordings WHERE status IN (\(Store.placeholders(values.count)))",
                    arguments: StatementArguments(values))
            else { return (0, 0, 0) }
            return (
                try row.decode(Int.self, forColumn: "parts"), try row.decode(Double.self, forColumn: "seconds"),
                try row.decode(Int.self, forColumn: "unknown_parts")
            )
        }
    }

    public func failedParts(limit: Int) throws -> (rows: [RecordingRow], total: Int) {
        let failed = PartStatus.failed.rawValue
        return try queue.read { db in
            let total = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM recordings WHERE status = ?", arguments: [failed])
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM recordings WHERE status = ? ORDER BY started_at, partkey LIMIT ?",
                arguments: [failed, limit]
            ).map { row throws(StoreError) in try RecordingRow(row: row) }
            return (rows, total ?? 0)
        }
    }

    public func quickCheck() throws -> String {
        try queue.read { try String.fetchOne($0, sql: "PRAGMA quick_check") ?? "" }
    }

    /// `grdb_migrations` が無ければ空配列
    public func appliedMigrations() throws -> [String] {
        try queue.read { try Schema.migrator().appliedMigrations($0) }
    }

    /// 状態の詳細の「結果待ちの Part の数」（T-32）
    public func awaitingDeleteResultCount() throws -> Int {
        try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recordings WHERE delete_request_id IS NOT NULL") ?? 0
        }
    }

    /// `Store.partkeys(statuses:)` と同じ SQL・束縛・並び（DR-15。T-32）
    public func partkeys(statuses: Set<PartStatus>) throws -> [String] {
        try queue.read { db in try Store.partkeys(db, statuses: statuses) }
    }
}
