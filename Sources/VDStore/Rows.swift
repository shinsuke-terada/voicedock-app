// recordings / sessions / events の 1 行（PLAN §7.2 の列と 1 対 1）。GRDB の永続化 API は使わない（PT-05）。
import GRDB
import VDCore

public struct RecordingRow: Equatable, Sendable {
    public let partkey: String
    public let deviceID: String  // device_id
    public let sourceFolder: String  // source_folder
    public let transmitterID: String  // transmitter_id
    public let micIndex: Int  // mic_index
    public let startedAt: String  // started_at
    public let durationSeconds: Double?  // duration_seconds
    public let endedAt: String?  // ended_at
    public let sourcePath: String?  // source_path
    public let sourceSize: Int64?  // source_size
    public let sourceMtime: Double?  // source_mtime
    public let sha256: String?
    public let sha256Helper: String?  // sha256_helper
    public let inboxPath: String?  // inbox_path
    public let stagingDir: String?  // staging_dir
    public let normalizedPath: String?  // normalized_path
    public let transcriptPath: String?  // transcript_path
    public let sessionKey: String?  // session_key
    public let status: PartStatus
    public let retryCount: Int  // retry_count
    public let errorCode: ErrorCode?  // error_code（未知の文字列は nil）
    public let errorCodeRaw: String?  // error_code の生の文字列（未知のコードもそのまま残す。列ではなく導出。Daily の警告行が使う）
    public let errorMessage: String?  // error_message
    public let sourceDeletedAt: String?  // source_deleted_at
    public let updatedAt: String  // updated_at
    public let deleteRequestID: String?  // delete_request_id
    public let duplicateOf: String?  // duplicate_of
    public let needsRecopy: Bool  // needs_recopy（0 / 1）

    init(row: Row) throws(StoreError) {
        let r = RowReader(row: row, table: "recordings", keyColumn: "partkey")
        partkey = try r.read(String.self, "partkey")
        deviceID = try r.read(String.self, "device_id")
        sourceFolder = try r.read(String.self, "source_folder")
        transmitterID = try r.read(String.self, "transmitter_id")
        micIndex = try r.read(Int.self, "mic_index")
        startedAt = try r.read(String.self, "started_at")
        durationSeconds = try r.read(Double?.self, "duration_seconds")
        endedAt = try r.read(String?.self, "ended_at")
        sourcePath = try r.read(String?.self, "source_path")
        sourceSize = try r.read(Int64?.self, "source_size")
        sourceMtime = try r.read(Double?.self, "source_mtime")
        sha256 = try r.read(String?.self, "sha256")
        sha256Helper = try r.read(String?.self, "sha256_helper")
        inboxPath = try r.read(String?.self, "inbox_path")
        stagingDir = try r.read(String?.self, "staging_dir")
        normalizedPath = try r.read(String?.self, "normalized_path")
        transcriptPath = try r.read(String?.self, "transcript_path")
        sessionKey = try r.read(String?.self, "session_key")
        guard let status = PartStatus(rawValue: try r.read(String.self, "status")) else {
            throw r.corrupt("status")
        }
        self.status = status
        retryCount = try r.read(Int.self, "retry_count")
        errorCodeRaw = try r.read(String?.self, "error_code")
        errorCode = errorCodeRaw.flatMap(ErrorCode.init(rawValue:))
        errorMessage = try r.read(String?.self, "error_message")
        sourceDeletedAt = try r.read(String?.self, "source_deleted_at")
        updatedAt = try r.read(String.self, "updated_at")
        deleteRequestID = try r.read(String?.self, "delete_request_id")
        duplicateOf = try r.read(String?.self, "duplicate_of")
        needsRecopy = try r.read(Int.self, "needs_recopy") != 0
    }
}

public struct SessionRow: Equatable, Sendable {
    public let sessionKey: String  // session_key
    public let dayDate: String  // day_date
    public let deviceID: String  // device_id
    public let startedAt: String?
    public let endedAt: String?
    public let recordedSeconds: Double?  // recorded_seconds
    public let partCount: Int  // part_count
    public let failedPartCount: Int  // failed_part_count
    public let title: String?
    public let analysisPath: String?  // analysis_path
    public let rawOutputPath: String?  // raw_output_path
    public let rawOutputSHA256: String?  // raw_output_sha256
    public let outputPath: String?  // output_path
    public let outputSHA256: String?  // output_sha256
    public let status: SessionStatus
    public let retryCount: Int
    public let regeneratedCount: Int  // regenerated_count
    public let deleteAttempts: Int  // delete_attempts
    public let errorCode: ErrorCode?
    public let errorMessage: String?
    public let sourceDeletedAt: String?
    public let updatedAt: String

    init(row: Row) throws(StoreError) {
        let r = RowReader(row: row, table: "sessions", keyColumn: "session_key")
        sessionKey = try r.read(String.self, "session_key")
        dayDate = try r.read(String.self, "day_date")
        deviceID = try r.read(String.self, "device_id")
        startedAt = try r.read(String?.self, "started_at")
        endedAt = try r.read(String?.self, "ended_at")
        recordedSeconds = try r.read(Double?.self, "recorded_seconds")
        partCount = try r.read(Int.self, "part_count")
        failedPartCount = try r.read(Int.self, "failed_part_count")
        title = try r.read(String?.self, "title")
        analysisPath = try r.read(String?.self, "analysis_path")
        rawOutputPath = try r.read(String?.self, "raw_output_path")
        rawOutputSHA256 = try r.read(String?.self, "raw_output_sha256")
        outputPath = try r.read(String?.self, "output_path")
        outputSHA256 = try r.read(String?.self, "output_sha256")
        guard let status = SessionStatus(rawValue: try r.read(String.self, "status")) else {
            throw r.corrupt("status")
        }
        self.status = status
        retryCount = try r.read(Int.self, "retry_count")
        regeneratedCount = try r.read(Int.self, "regenerated_count")
        deleteAttempts = try r.read(Int.self, "delete_attempts")
        errorCode = try r.read(String?.self, "error_code").flatMap(ErrorCode.init(rawValue:))
        errorMessage = try r.read(String?.self, "error_message")
        sourceDeletedAt = try r.read(String?.self, "source_deleted_at")
        updatedAt = try r.read(String.self, "updated_at")
    }
}

public struct EventRow: Equatable, Sendable {
    public let id: Int64
    public let entityType: EntityType  // entity_type
    public let entityKey: String  // entity_key
    public let fromStatus: String?  // from_status（行の作成は nil）
    public let toStatus: String  // to_status
    public let errorCode: String?  // error_code（文字列のまま）
    public let detail: String?
    public let createdAt: String  // created_at

    init(row: Row) throws(StoreError) {
        let r = RowReader(row: row, table: "events", keyColumn: "id")
        id = try r.read(Int64.self, "id")
        guard let entityType = EntityType(rawValue: try r.read(String.self, "entity_type")) else {
            throw .corruptRow("events.entity_type id=" + String(id))
        }
        self.entityType = entityType
        entityKey = try r.read(String.self, "entity_key")
        fromStatus = try r.read(String?.self, "from_status")
        toStatus = try r.read(String.self, "to_status")
        errorCode = try r.read(String?.self, "error_code")
        detail = try r.read(String?.self, "detail")
        createdAt = try r.read(String.self, "created_at")
    }
}

/// 行の作成（insertRecording）に渡す列。status は DISCOVERED 固定、updated_at は now、その他の列は既定（NULL / 0）
public struct NewRecording: Equatable, Sendable {
    public let partkey: String
    public let deviceID: String
    public let sourceFolder: String
    public let transmitterID: String
    public let micIndex: Int
    public let startedAt: String
    public let durationSeconds: Double?
    public let endedAt: String?
    public let sourcePath: String
    public let sourceSize: Int64
    public let sourceMtime: Double
    public let sha256Helper: String
    public let inboxPath: String
    public init(
        partkey: String, deviceID: String, sourceFolder: String, transmitterID: String, micIndex: Int,
        startedAt: String, durationSeconds: Double?, endedAt: String?, sourcePath: String,
        sourceSize: Int64, sourceMtime: Double, sha256Helper: String, inboxPath: String
    ) {
        self.partkey = partkey
        self.deviceID = deviceID
        self.sourceFolder = sourceFolder
        self.transmitterID = transmitterID
        self.micIndex = micIndex
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.endedAt = endedAt
        self.sourcePath = sourcePath
        self.sourceSize = sourceSize
        self.sourceMtime = sourceMtime
        self.sha256Helper = sha256Helper
        self.inboxPath = inboxPath
    }
}

/// 行の作成（insertSession）に渡す列。status は OPEN 固定、updated_at は now
public struct NewSession: Equatable, Sendable {
    public let sessionKey: String
    public let dayDate: String  // yyyy-MM-dd
    public let deviceID: String
    public init(sessionKey: String, dayDate: String, deviceID: String) {
        self.sessionKey = sessionKey
        self.dayDate = dayDate
        self.deviceID = deviceID
    }
}

/// 1 行の列を `row.decode` で読み、失敗を `StoreError.corruptRow("<table>.<column> key=<主キーの値か ?>")` に写す（CR-04 / CR-16）。
private struct RowReader {
    let row: Row
    let table: String
    let key: String

    init(row: Row, table: String, keyColumn: String) {
        self.row = row
        self.table = table
        if let text = try? row.decode(String?.self, forColumn: keyColumn) {
            key = text
        } else if let number = try? row.decode(Int64?.self, forColumn: keyColumn) {
            key = String(number)
        } else {
            key = "?"
        }
    }

    func read<T: DatabaseValueConvertible>(_ type: T.Type, _ column: String) throws(StoreError) -> T {
        do {
            return try row.decode(T.self, forColumn: column)
        } catch {
            throw corrupt(column)
        }
    }

    func corrupt(_ column: String) -> StoreError {
        .corruptRow(table + "." + column + " key=" + key)
    }
}
