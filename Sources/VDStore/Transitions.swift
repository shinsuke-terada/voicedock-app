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
        let storedDetail = kind == .recovery ? Store.recoveryDetail : detail
        try transition(
            entity: .session, key: sessionKey, from: from.rawValue, to: to.rawValue,
            retry: Store.sessionRetry(to: to, resetRetry: resetRetry),
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
        try pool.write { db in try Store.insertSessionRow(db, row, now: now) }
    }

    /// 分組の 1 件（PLAN §5.6。F-82）。Session が無ければ作り（OPEN。events に NULL→OPEN）、Part に session_key を書き、
    /// Session の集計列を数え直し、Session が OPEN なら `OPEN→OPEN`（detail = partkey。新規作成の直後も書く。SM-02）までを
    /// **1 トランザクション**で行う（途中で落ちて、分組したのに集計も events も無い行を残さない）。閉じた Session への追加は events を書かない。
    /// 返り値は分組した時点の Session の状態（新規作成なら OPEN）。再オープンするかは呼び手が決める（SM-11 / SM-12）
    public func groupPart(_ partkey: String, into session: NewSession) throws -> SessionStatus {
        guard TransitionTable.allows(Edge(SessionStatus.open, .open), kind: .normal) else {
            throw IllegalTransition(from: SessionStatus.open.rawValue, to: SessionStatus.open.rawValue, kind: .normal)
        }
        let key = session.sessionKey
        let now = nowISO()
        return try pool.write { db in
            let status: SessionStatus
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM sessions WHERE session_key = ?", arguments: [key]) {
                status = try SessionRow(row: row).status
            } else {
                try Store.insertSessionRow(db, session, now: now)
                status = .open
            }
            try db.execute(
                sql: "UPDATE recordings SET session_key = ?, updated_at = ? WHERE partkey = ?",
                arguments: [key, now, partkey])
            try Store.refreshSessionAggregates(db, key: key, now: now)
            if status == .open {
                try Store.applyTransition(
                    db, entity: .session, key: key, from: SessionStatus.open.rawValue, to: SessionStatus.open.rawValue,
                    retry: Store.sessionRetry(to: .open, resetRetry: false), errorCode: nil, errorMessage: nil,
                    detail: partkey, now: now)
            }
            return status
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
            try Store.applyTransition(
                db, entity: entity, key: key, from: from, to: to, retry: retry, errorCode: errorCode,
                errorMessage: errorMessage, detail: detail, now: now)
        }
    }

    /// transition の SQL を与えられた db で実行する（groupPart が同じトランザクションで使う。同じ SQL を 2 か所に書かない。CR-06）
    static func applyTransition(
        _ db: Database, entity: EntityType, key: String, from: String, to: String, retry: RetryExpression,
        errorCode: String?, errorMessage: String?, detail: String?, now: String
    ) throws {
        try db.execute(
            sql:
                "UPDATE \(entity.table) SET status = ?, retry_count = \(retry.sql), error_code = ?, error_message = ?, updated_at = ? "
                + "WHERE \(entity.keyColumn) = ? AND status = ?",
            arguments: [to, errorCode, errorMessage.map(TextLimit.truncate200), now, key, from])
        guard db.changesCount == 1 else { throw TransitionConflict(key: key, expected: from) }
        try Store.insertEvent(
            db, entity: entity, key: key, from: from, to: to, errorCode: errorCode, detail: detail, createdAt: now)
    }

    /// Session の行の作成（insertSession と groupPart が同じトランザクションで使う）
    static func insertSessionRow(_ db: Database, _ row: NewSession, now: String) throws {
        try db.execute(
            sql: "INSERT INTO sessions (session_key, day_date, device_id, status, updated_at) VALUES (?, ?, ?, ?, ?)",
            arguments: [row.sessionKey, row.dayDate, row.deviceID, SessionStatus.open.rawValue, now])
        try Store.insertEvent(
            db, entity: .session, key: row.sessionKey, from: nil, to: SessionStatus.open.rawValue,
            errorCode: nil, detail: nil, createdAt: now)
    }

    /// Session の遷移の retry_count の式（SM-03 / SM-04）
    static func sessionRetry(to: SessionStatus, resetRetry: Bool) -> RetryExpression {
        if resetRetry || SessionStates.retryReset.contains(to) { return .reset }
        return to == .failed ? .increment : .keep
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
