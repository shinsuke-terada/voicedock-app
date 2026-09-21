// 状態を変える唯一の API（遷移と行の作成）。遷移表の検査・楽観的同時実行制御・events を 1 トランザクションで（PLAN §5.2）。
import GRDB
import VDCore

public struct TransitionConflict: Error, Equatable, Sendable {
    public let key: String
    public let expected: String  // 期待した from の rawValue
}

public struct IllegalTransition: Error, Equatable, Sendable {
    public let from: String
    public let to: String
    public let kind: TransitionKind
}

extension Store {
    public func recordPartTransition(
        partkey: String, from: PartStatus, to: PartStatus, kind: TransitionKind = .normal,
        errorCode: ErrorCode? = nil, errorMessage: String? = nil,
        detail: String? = nil, resetRetry: Bool = false
    ) throws {
        let edge = Edge(from, to)
        guard TransitionTable.allows(edge, kind: kind) else {
            throw IllegalTransition(from: from.rawValue, to: to.rawValue, kind: kind)
        }
        let retry: RetryExpression
        if resetRetry || PartStates.retryReset.contains(to) {
            retry = .reset
        } else if to == .failed {
            retry = .increment
        } else {
            retry = .keep
        }
        let storedDetail = kind == .recovery ? Store.recoveryDetail : detail
        try transition(
            entity: .recording, key: partkey, from: from.rawValue, to: to.rawValue, retry: retry,
            errorCode: errorCode?.rawValue, errorMessage: errorMessage, detail: storedDetail)
    }

    public func recordSessionTransition(
        sessionKey: String, from: SessionStatus, to: SessionStatus, kind: TransitionKind = .normal,
        errorCode: ErrorCode? = nil, errorMessage: String? = nil,
        detail: String? = nil, resetRetry: Bool = false
    ) throws {
        let edge = Edge(from, to)
        guard TransitionTable.allows(edge, kind: kind) else {
            throw IllegalTransition(from: from.rawValue, to: to.rawValue, kind: kind)
        }
        let retry: RetryExpression
        if resetRetry || SessionStates.retryReset.contains(to) {
            retry = .reset
        } else if to == .failed {
            retry = .increment
        } else {
            retry = .keep
        }
        let storedDetail = kind == .recovery ? Store.recoveryDetail : detail
        try transition(
            entity: .session, key: sessionKey, from: from.rawValue, to: to.rawValue, retry: retry,
            errorCode: errorCode?.rawValue, errorMessage: errorMessage, detail: storedDetail)
    }

    public func insertRecording(_ row: NewRecording) throws {
        let now = nowISO()
        try pool.write { db in
            try db.execute(
                sql:
                    "INSERT INTO recordings (partkey, device_id, source_folder, transmitter_id, mic_index, started_at, duration_seconds, ended_at, "
                    + "source_path, source_size, source_mtime, sha256_helper, inbox_path, status, updated_at) "
                    + "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [
                    row.partkey, row.deviceID, row.sourceFolder, row.transmitterID, row.micIndex, row.startedAt,
                    row.durationSeconds, row.endedAt, row.sourcePath, row.sourceSize, row.sourceMtime,
                    row.sha256Helper, row.inboxPath, PartStatus.discovered.rawValue, now,
                ])
            try Store.insertEvent(
                db, entity: .recording, key: row.partkey, from: nil, to: PartStatus.discovered.rawValue,
                errorCode: nil, detail: nil, createdAt: now)
        }
    }

    public func insertSession(_ row: NewSession) throws {
        let now = nowISO()
        try pool.write { db in
            try db.execute(
                sql:
                    "INSERT INTO sessions (session_key, day_date, device_id, status, updated_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [row.sessionKey, row.dayDate, row.deviceID, SessionStatus.open.rawValue, now])
            try Store.insertEvent(
                db, entity: .session, key: row.sessionKey, from: nil, to: SessionStatus.open.rawValue,
                errorCode: nil, detail: nil, createdAt: now)
        }
    }

    /// status が期待どおりのときだけ列を更新する（状態は変えない）。更新したら true
    public func updateRecordingIfStatus(_ partkey: String, status: PartStatus, _ fields: [RecordingField]) throws
        -> Bool
    {
        guard !fields.isEmpty else { return false }
        let assignments = try RecordingField.assignments(fields)
        let now = nowISO()
        return try pool.write { db in
            try db.execute(
                sql: "UPDATE recordings SET \(assignments.sql), updated_at = ? WHERE partkey = ? AND status = ?",
                arguments: StatementArguments(assignments.values + [now, partkey, status.rawValue]))
            return db.changesCount == 1
        }
    }

    /// 遷移の本体。UPDATE と events の INSERT を 1 トランザクションで行い、行が期待の状態でなければ
    /// `TransitionConflict` を投げてロールバックする（楽観的同時実行制御。PLAN §5.2）
    func transition(
        entity: EntityType, key: String, from: String, to: String, retry: RetryExpression,
        errorCode: String?, errorMessage: String?, detail: String?
    ) throws {
        let now = nowISO()
        try pool.write { db in
            try db.execute(
                sql:
                    "UPDATE \(entity.table) SET status = ?, retry_count = \(retry.sql), error_code = ?, error_message = ?, updated_at = ? "
                    + "WHERE \(entity.keyColumn) = ? AND status = ?",
                arguments: [to, errorCode, errorMessage.map(TextLimit.truncate200), now, key, from])
            guard db.changesCount == 1 else { throw TransitionConflict(key: key, expected: from) }
            try Store.insertEvent(
                db, entity: entity, key: key, from: from, to: to, errorCode: errorCode, detail: detail, createdAt: now)
        }
    }

    static func insertEvent(
        _ db: Database, entity: EntityType, key: String, from: String?, to: String,
        errorCode: String?, detail: String?, createdAt: String
    ) throws {
        try db.execute(
            sql:
                "INSERT INTO events (entity_type, entity_key, from_status, to_status, error_code, detail, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            arguments: [entity.rawValue, key, from, to, errorCode, detail.map(TextLimit.truncate200), createdAt])
    }
}

enum RetryExpression {
    case reset, increment, keep
    var sql: String {
        switch self {
        case .reset: "0"
        case .increment: "retry_count + 1"
        case .keep: "retry_count"
        }
    }
}
