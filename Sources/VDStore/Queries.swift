// 問い合わせ（CONC-02。PLAN §5.3・§5.6・§7.2）。並び順は voicedock db.py:436-545 と同じ。
import GRDB
import VDCore

extension Store {
    /// knownPartkeys の 1 回の問い合わせに入れる件数
    static let knownPartkeysChunk = 500

    public func recording(_ partkey: String) throws -> RecordingRow? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM recordings WHERE partkey = ?", arguments: [partkey])
                .map { row throws(StoreError) in try RecordingRow(row: row) }
        }
    }

    public func session(_ key: String) throws -> SessionRow? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE session_key = ?", arguments: [key])
                .map { row throws(StoreError) in try SessionRow(row: row) }
        }
    }

    public func ungroupedRecordings() throws -> [RecordingRow] {
        try recordingRows("SELECT * FROM recordings WHERE session_key IS NULL ORDER BY started_at, partkey", [])
    }

    public func recordings(inSession key: String) throws -> [RecordingRow] {
        try recordingRows("SELECT * FROM recordings WHERE session_key = ? ORDER BY started_at, partkey", [key])
    }

    public func recordings(status: PartStatus) throws -> [RecordingRow] {
        try recordingRows("SELECT * FROM recordings WHERE status = ? ORDER BY started_at, partkey", [status.rawValue])
    }

    public func sessions(status: SessionStatus) throws -> [SessionRow] {
        try sessionRows("SELECT * FROM sessions WHERE status = ? ORDER BY session_key", [status.rawValue])
    }

    public func nonTerminalPartkeys() throws -> [String] {
        let values = PartStates.terminal.map(\.rawValue).sorted()
        return try pool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT partkey FROM recordings WHERE status NOT IN (\(Store.placeholders(values.count))) "
                    + "ORDER BY started_at, partkey",
                arguments: StatementArguments(values))
        }
    }

    public func failedRecordingKeys() throws -> [String] {
        try pool.read { db in
            try String.fetchAll(
                db, sql: "SELECT partkey FROM recordings WHERE status = ? ORDER BY updated_at, partkey",
                arguments: [PartStatus.failed.rawValue])
        }
    }

    public func failedSessionKeys() throws -> [String] {
        try pool.read { db in
            try String.fetchAll(
                db, sql: "SELECT session_key FROM sessions WHERE status = ? ORDER BY updated_at, session_key",
                arguments: [SessionStatus.failed.rawValue])
        }
    }

    public func failedFromPart(_ partkey: String) throws -> PartStatus? {
        try failedFrom(.recording, partkey, failed: PartStatus.failed.rawValue).flatMap(PartStatus.init(rawValue:))
    }

    public func failedFromSession(_ key: String) throws -> SessionStatus? {
        try failedFrom(.session, key, failed: SessionStatus.failed.rawValue).flatMap(SessionStatus.init(rawValue:))
    }

    /// 状態で絞らない（集合は呼び手の `SessionStates.deleteEvaluated`）
    public func sessionsForDeleteEvaluation() throws -> [SessionRow] {
        try sessionRows("SELECT * FROM sessions ORDER BY updated_at, session_key", [])
    }

    /// 決定性のため `ORDER BY partkey` を足した（voicedock は並びなし）
    public func recording(normalizedPath: String) throws -> RecordingRow? {
        try recordingRows(
            "SELECT * FROM recordings WHERE normalized_path = ? ORDER BY partkey LIMIT 1", [normalizedPath]
        ).first
    }

    /// 部分 UNIQUE なので 0 か 1 行
    public func recording(sha256: String) throws -> RecordingRow? {
        try recordingRows("SELECT * FROM recordings WHERE sha256 = ?", [sha256]).first
    }

    public func recordingsAwaitingDeleteResult() throws -> [RecordingRow] {
        try recordingRows(
            "SELECT * FROM recordings WHERE delete_request_id IS NOT NULL ORDER BY started_at, partkey", [])
    }

    public func recordingsNeedingRecopy() throws -> [RecordingRow] {
        try recordingRows("SELECT * FROM recordings WHERE needs_recopy = 1 ORDER BY started_at, partkey", [])
    }

    /// 状態の集合で partkey を引く（partkey 順。inbox の取り残しの判定。T-18）。空集合なら問い合わせずに []
    public func partkeys(statuses: Set<PartStatus>) throws -> [String] {
        try pool.read { db in try Store.partkeys(db, statuses: statuses) }
    }

    public func events(entity: EntityType, key: String) throws -> [EventRow] {
        try pool.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM events WHERE entity_type = ? AND entity_key = ? ORDER BY id",
                arguments: [entity.rawValue, key]
            ).map { row throws(StoreError) in try EventRow(row: row) }
        }
    }

    /// 500 件ずつに分けて問い合わせ、結果を合わせる。空なら問い合わせずに空集合
    public func knownPartkeys(_ keys: [String]) throws -> Set<String> {
        guard !keys.isEmpty else { return [] }
        return try pool.read { db in
            var known: Set<String> = []
            for start in stride(from: 0, to: keys.count, by: Store.knownPartkeysChunk) {
                let chunk = Array(keys[start..<min(start + Store.knownPartkeysChunk, keys.count)])
                let found = try String.fetchAll(
                    db, sql: "SELECT partkey FROM recordings WHERE partkey IN (\(Store.placeholders(chunk.count)))",
                    arguments: StatementArguments(chunk))
                known.formUnion(found)
            }
            return known
        }
    }

    public func importedKeys() throws -> Set<String> {
        try pool.read { db in try String.fetchSet(db, sql: "SELECT partkey FROM imported_keys") }
    }

    /// アプリの DB に行がある partkey と、既に入っている partkey は入らない（PLAN §8.13）。追加した件数を返す
    public func insertImportedKeys(_ rows: [(partkey: String, sourceNote: String)]) throws -> Int {
        try pool.write { db in
            var added = 0
            for row in rows {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO imported_keys (partkey, source_note, imported_at) "
                        + "SELECT ?, ?, ? WHERE NOT EXISTS (SELECT 1 FROM recordings WHERE partkey = ?)",
                    arguments: [row.partkey, row.sourceNote, nowISO(), row.partkey])
                added += db.changesCount
            }
            return added
        }
    }

    /// Session の集計列を数え直す（PLAN §5.6。voicedock session.py:244-270）
    public func refreshSessionAggregates(_ key: String) throws {
        try pool.write { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) AS parts, MIN(started_at) AS first_at, MAX(ended_at) AS last_at, "
                        + "SUM(duration_seconds) AS seconds, "
                        + "COALESCE(SUM(CASE WHEN status IN (?, ?) THEN 1 ELSE 0 END), 0) AS excluded "
                        + "FROM recordings WHERE session_key = ?",
                    arguments: [PartStatus.failed.rawValue, PartStatus.skipped.rawValue, key])
            else { return }
            let parts = try row.decode(Int.self, forColumn: "parts")
            let firstAt = try row.decode(String?.self, forColumn: "first_at")
            let lastAt = try row.decode(String?.self, forColumn: "last_at")
            let seconds = try row.decode(Double?.self, forColumn: "seconds")
            let excluded = try row.decode(Int.self, forColumn: "excluded")
            try Store.applySessionUpdate(
                db, key: key,
                fields: [
                    .partCount(parts), .startedAt(firstAt), .endedAt(lastAt), .recordedSeconds(seconds),
                    .failedPartCount(excluded),
                ], now: nowISO())
        }
    }

    /// `IN (?, …)` の `?` を束縛する値の数から作る（値を SQL に埋め込まない）
    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    /// partkeys(statuses:) の本体。ReadOnlyStore と同じ SQL・束縛・並びを使う（DR-15）
    static func partkeys(_ db: Database, statuses: Set<PartStatus>) throws -> [String] {
        guard !statuses.isEmpty else { return [] }
        let values = statuses.map(\.rawValue).sorted()
        return try String.fetchAll(
            db, sql: "SELECT partkey FROM recordings WHERE status IN (\(placeholders(values.count))) ORDER BY partkey",
            arguments: StatementArguments(values))
    }

    private func failedFrom(_ entity: EntityType, _ key: String, failed: String) throws -> String? {
        try pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT from_status FROM events WHERE entity_type = ? AND entity_key = ? AND to_status = ? "
                    + "ORDER BY id DESC LIMIT 1",
                arguments: [entity.rawValue, key, failed])
        }
    }

    private func recordingRows(_ sql: String, _ arguments: StatementArguments) throws -> [RecordingRow] {
        try pool.read { db in
            try Row.fetchAll(db, sql: sql, arguments: arguments).map { row throws(StoreError) in
                try RecordingRow(row: row)
            }
        }
    }

    private func sessionRows(_ sql: String, _ arguments: StatementArguments) throws -> [SessionRow] {
        try pool.read { db in
            try Row.fetchAll(db, sql: sql, arguments: arguments).map { row throws(StoreError) in
                try SessionRow(row: row)
            }
        }
    }
}
