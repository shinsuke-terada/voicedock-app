// status 以外の列の更新（PLAN §5.2）。updated_at は常に now で上書きする。
import GRDB
import VDCore

public enum RecordingField: Sendable, Equatable {
    case sessionKey(String?)
    case durationSeconds(Double?)
    case endedAt(String?)
    case sha256(String?)
    case sha256Helper(String?)
    case inboxPath(String?)
    case stagingDir(String?)
    case normalizedPath(String?)
    case transcriptPath(String?)
    case sourceSize(Int64?)
    case sourceMtime(Double?)
    case errorCode(ErrorCode?)
    case errorMessage(String?)
    case sourceDeletedAt(String?)
    case deleteRequestID(String?)
    case duplicateOf(String?)
    case needsRecopy(Bool)

    /// 列名と束縛する値（status を表す case は無い）
    var assignment: (column: String, value: (any DatabaseValueConvertible)?) {
        switch self {
        case .sessionKey(let v): ("session_key", v)
        case .durationSeconds(let v): ("duration_seconds", v)
        case .endedAt(let v): ("ended_at", v)
        case .sha256(let v): ("sha256", v)
        case .sha256Helper(let v): ("sha256_helper", v)
        case .inboxPath(let v): ("inbox_path", v)
        case .stagingDir(let v): ("staging_dir", v)
        case .normalizedPath(let v): ("normalized_path", v)
        case .transcriptPath(let v): ("transcript_path", v)
        case .sourceSize(let v): ("source_size", v)
        case .sourceMtime(let v): ("source_mtime", v)
        case .errorCode(let v): ("error_code", v?.rawValue)
        case .errorMessage(let v): ("error_message", v.map(TextLimit.truncate200))
        case .sourceDeletedAt(let v): ("source_deleted_at", v)
        case .deleteRequestID(let v): ("delete_request_id", v)
        case .duplicateOf(let v): ("duplicate_of", v)
        case .needsRecopy(let v): ("needs_recopy", v ? 1 : 0)
        }
    }

    /// 渡された順に `"<column> = ?"` を並べる。同じ列が 2 回現れたら invalidUpdate（黙って後勝ちにしない）
    static func assignments(_ fields: [RecordingField]) throws(StoreError) -> Assignments {
        try Assignments.make(fields.map(\.assignment))
    }
}

public enum SessionField: Sendable, Equatable {
    case startedAt(String?)
    case endedAt(String?)
    case recordedSeconds(Double?)
    case partCount(Int)
    case failedPartCount(Int)
    case title(String?)
    case analysisPath(String?)
    case rawOutputPath(String?)
    case rawOutputSHA256(String?)
    case outputPath(String?)
    case outputSHA256(String?)
    case regeneratedCount(Int)
    case deleteAttempts(Int)
    case errorCode(ErrorCode?)
    case errorMessage(String?)
    case sourceDeletedAt(String?)

    /// 列名と束縛する値（status を表す case は無い）
    var assignment: (column: String, value: (any DatabaseValueConvertible)?) {
        switch self {
        case .startedAt(let v): ("started_at", v)
        case .endedAt(let v): ("ended_at", v)
        case .recordedSeconds(let v): ("recorded_seconds", v)
        case .partCount(let v): ("part_count", v)
        case .failedPartCount(let v): ("failed_part_count", v)
        case .title(let v): ("title", v)
        case .analysisPath(let v): ("analysis_path", v)
        case .rawOutputPath(let v): ("raw_output_path", v)
        case .rawOutputSHA256(let v): ("raw_output_sha256", v)
        case .outputPath(let v): ("output_path", v)
        case .outputSHA256(let v): ("output_sha256", v)
        case .regeneratedCount(let v): ("regenerated_count", v)
        case .deleteAttempts(let v): ("delete_attempts", v)
        case .errorCode(let v): ("error_code", v?.rawValue)
        case .errorMessage(let v): ("error_message", v.map(TextLimit.truncate200))
        case .sourceDeletedAt(let v): ("source_deleted_at", v)
        }
    }

    /// 渡された順に `"<column> = ?"` を並べる。同じ列が 2 回現れたら invalidUpdate（黙って後勝ちにしない）
    static func assignments(_ fields: [SessionField]) throws(StoreError) -> Assignments {
        try Assignments.make(fields.map(\.assignment))
    }
}

extension Store {
    public func updateRecording(_ partkey: String, _ fields: [RecordingField]) throws {
        guard !fields.isEmpty else { return }
        let a = try RecordingField.assignments(fields)
        let now = nowISO()
        try pool.write { db in
            try Store.executeRecordingUpdate(db, partkey: partkey, a, now: now)
        }
    }

    /// updateRecording の SQL を与えられた db で実行する（分組の groupPart が同じトランザクションで使う。F-82）
    static func applyRecordingUpdate(_ db: Database, partkey: String, fields: [RecordingField], now: String) throws {
        guard !fields.isEmpty else { return }
        try executeRecordingUpdate(db, partkey: partkey, try RecordingField.assignments(fields), now: now)
    }

    /// updateRecording と applyRecordingUpdate が共有する SQL（同じ SQL を 2 か所に書かない。CR-06）
    private static func executeRecordingUpdate(_ db: Database, partkey: String, _ a: Assignments, now: String) throws {
        try db.execute(
            sql: "UPDATE recordings SET \(a.sql), updated_at = ? WHERE partkey = ?",
            arguments: StatementArguments(a.values + [now, partkey]))
    }

    public func updateSession(_ key: String, _ fields: [SessionField]) throws {
        guard !fields.isEmpty else { return }
        let a = try SessionField.assignments(fields)
        let now = nowISO()
        try pool.write { db in
            try Store.executeSessionUpdate(db, key: key, a, now: now)
        }
    }

    /// updateSession の SQL を与えられた db で実行する（refreshSessionAggregates が同じトランザクションで使う）
    static func applySessionUpdate(_ db: Database, key: String, fields: [SessionField], now: String) throws {
        try executeSessionUpdate(db, key: key, try SessionField.assignments(fields), now: now)
    }

    /// updateSession と applySessionUpdate が共有する SQL（同じ SQL を 2 か所に書かない。CR-06）
    private static func executeSessionUpdate(_ db: Database, key: String, _ a: Assignments, now: String) throws {
        try db.execute(
            sql: "UPDATE sessions SET \(a.sql), updated_at = ? WHERE session_key = ?",
            arguments: StatementArguments(a.values + [now, key]))
    }
}

struct Assignments {
    let sql: String
    let values: [(any DatabaseValueConvertible)?]

    /// (列名, 値) の並びから組み立てる。同じ列が 2 回現れたら invalidUpdate
    static func make(_ pairs: [(column: String, value: (any DatabaseValueConvertible)?)]) throws(StoreError)
        -> Assignments
    {
        var seen: Set<String> = []
        for pair in pairs {
            guard seen.insert(pair.column).inserted else { throw .invalidUpdate(pair.column) }
        }
        return Assignments(
            sql: pairs.map { $0.column + " = ?" }.joined(separator: ", "), values: pairs.map(\.value))
    }
}
