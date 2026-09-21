// スキーマ（PLAN §7.2）。期待表は PLAN §7.2 の DDL から写した。
import Foundation
import GRDB
import TestSupport
import Testing
import VDCore

@testable import VDStore

@Suite("スキーマ")
struct SchemaTests {
    /// `PRAGMA table_info` の 1 行（name, type, notnull, dflt_value, pk）
    struct Column: Equatable, CustomStringConvertible {
        let name: String
        let type: String
        let notnull: Int
        let dflt: String?
        let pk: Int

        init(_ name: String, _ type: String, _ notnull: Int, _ dflt: String?, _ pk: Int) {
            self.name = name
            self.type = type
            self.notnull = notnull
            self.dflt = dflt
            self.pk = pk
        }

        var description: String { "(\(name), \(type), \(notnull), \(dflt ?? "NULL"), \(pk))" }
    }

    static let recordings: [Column] = [
        Column("partkey", "TEXT", 1, nil, 1),
        Column("device_id", "TEXT", 1, nil, 0),
        Column("source_folder", "TEXT", 1, nil, 0),
        Column("transmitter_id", "TEXT", 1, nil, 0),
        Column("mic_index", "INTEGER", 1, nil, 0),
        Column("started_at", "TEXT", 1, nil, 0),
        Column("duration_seconds", "REAL", 0, nil, 0),
        Column("ended_at", "TEXT", 0, nil, 0),
        Column("source_path", "TEXT", 0, nil, 0),
        Column("source_size", "INTEGER", 0, nil, 0),
        Column("source_mtime", "REAL", 0, nil, 0),
        Column("sha256", "TEXT", 0, nil, 0),
        Column("sha256_helper", "TEXT", 0, nil, 0),
        Column("inbox_path", "TEXT", 0, nil, 0),
        Column("staging_dir", "TEXT", 0, nil, 0),
        Column("normalized_path", "TEXT", 0, nil, 0),
        Column("transcript_path", "TEXT", 0, nil, 0),
        Column("session_key", "TEXT", 0, nil, 0),
        Column("status", "TEXT", 1, nil, 0),
        Column("retry_count", "INTEGER", 1, "0", 0),
        Column("error_code", "TEXT", 0, nil, 0),
        Column("error_message", "TEXT", 0, nil, 0),
        Column("source_deleted_at", "TEXT", 0, nil, 0),
        Column("updated_at", "TEXT", 1, nil, 0),
        Column("delete_request_id", "TEXT", 0, nil, 0),
        Column("duplicate_of", "TEXT", 0, nil, 0),
        Column("needs_recopy", "INTEGER", 1, "0", 0),
    ]

    static let sessions: [Column] = [
        Column("session_key", "TEXT", 1, nil, 1),
        Column("day_date", "TEXT", 1, nil, 0),
        Column("device_id", "TEXT", 1, nil, 0),
        Column("started_at", "TEXT", 0, nil, 0),
        Column("ended_at", "TEXT", 0, nil, 0),
        Column("recorded_seconds", "REAL", 0, nil, 0),
        Column("part_count", "INTEGER", 1, "0", 0),
        Column("failed_part_count", "INTEGER", 1, "0", 0),
        Column("title", "TEXT", 0, nil, 0),
        Column("analysis_path", "TEXT", 0, nil, 0),
        Column("raw_output_path", "TEXT", 0, nil, 0),
        Column("raw_output_sha256", "TEXT", 0, nil, 0),
        Column("output_path", "TEXT", 0, nil, 0),
        Column("output_sha256", "TEXT", 0, nil, 0),
        Column("status", "TEXT", 1, nil, 0),
        Column("retry_count", "INTEGER", 1, "0", 0),
        Column("regenerated_count", "INTEGER", 1, "0", 0),
        Column("delete_attempts", "INTEGER", 1, "0", 0),
        Column("error_code", "TEXT", 0, nil, 0),
        Column("error_message", "TEXT", 0, nil, 0),
        Column("source_deleted_at", "TEXT", 0, nil, 0),
        Column("updated_at", "TEXT", 1, nil, 0),
    ]

    static let events: [Column] = [
        Column("id", "INTEGER", 0, nil, 1),
        Column("entity_type", "TEXT", 1, nil, 0),
        Column("entity_key", "TEXT", 1, nil, 0),
        Column("from_status", "TEXT", 0, nil, 0),
        Column("to_status", "TEXT", 1, nil, 0),
        Column("error_code", "TEXT", 0, nil, 0),
        Column("detail", "TEXT", 0, nil, 0),
        Column("created_at", "TEXT", 1, nil, 0),
    ]

    static let importedKeys: [Column] = [
        Column("partkey", "TEXT", 1, nil, 1),
        Column("source_note", "TEXT", 1, nil, 0),
        Column("imported_at", "TEXT", 1, nil, 0),
    ]

    /// スキーマの PRAGMA は writer で読む（GRDB の reader では index_list・foreign_key_list が空を返す）
    func tableInfo(_ f: StoreFixture, _ table: String) throws -> [Column] {
        try f.store.pool.writeWithoutTransaction { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { row in
                Column(
                    try row.decode(String.self, forColumn: "name"), try row.decode(String.self, forColumn: "type"),
                    try row.decode(Int.self, forColumn: "notnull"),
                    try row.decode(String?.self, forColumn: "dflt_value"), try row.decode(Int.self, forColumn: "pk"))
            }
        }
    }

    @Test("列数は recordings 27・sessions 22・events 8・imported_keys 3")
    func columnCountsAreFixed() throws {
        let f = try StoreFixture()
        #expect(try tableInfo(f, "recordings").count == 27)
        #expect(try tableInfo(f, "sessions").count == 22)
        #expect(try tableInfo(f, "events").count == 8)
        #expect(try tableInfo(f, "imported_keys").count == 3)
    }

    @Test("recordings の列は PLAN §7.2 と同じ（名前・型・NOT NULL・既定値・順）")
    func recordingsColumnsMatchPlan() throws {
        let f = try StoreFixture()
        #expect(try tableInfo(f, "recordings") == Self.recordings)
    }

    @Test("sessions の列は PLAN §7.2 と同じ")
    func sessionsColumnsMatchPlan() throws {
        let f = try StoreFixture()
        #expect(try tableInfo(f, "sessions") == Self.sessions)
    }

    @Test("events と imported_keys の列は PLAN §7.2 と同じ")
    func eventsAndImportedKeysColumnsMatchPlan() throws {
        let f = try StoreFixture()
        #expect(try tableInfo(f, "events") == Self.events)
        #expect(try tableInfo(f, "imported_keys") == Self.importedKeys)
    }

    /// 索引の名前・unique・partial・列（CREATE INDEX で作ったものだけ。主キーの自動索引は除く）
    struct Index: Equatable, CustomStringConvertible {
        let name: String
        let unique: Int
        let partial: Int
        let columns: [String]
        var description: String { "\(name)(\(columns.joined(separator: ", "))) unique=\(unique) partial=\(partial)" }
    }

    func indexes(_ f: StoreFixture, _ table: String) throws -> [Index] {
        try f.store.pool.writeWithoutTransaction { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA index_list(\(table))")
            var result: [Index] = []
            for row in rows {
                guard try row.decode(String.self, forColumn: "origin") == "c" else { continue }
                let name = try row.decode(String.self, forColumn: "name")
                let columns = try Row.fetchAll(db, sql: "PRAGMA index_info(\(name))")
                    .sorted { try $0.decode(Int.self, forColumn: "seqno") < $1.decode(Int.self, forColumn: "seqno") }
                    .map { try $0.decode(String.self, forColumn: "name") }
                result.append(
                    Index(
                        name: name, unique: try row.decode(Int.self, forColumn: "unique"),
                        partial: try row.decode(Int.self, forColumn: "partial"), columns: columns))
            }
            return result.sorted { $0.name < $1.name }
        }
    }

    @Test("索引は PLAN §7.2 と同じ")
    func indexesMatchPlan() throws {
        let f = try StoreFixture()
        #expect(
            try indexes(f, "sessions") == [
                Index(name: "idx_sessions_day", unique: 0, partial: 0, columns: ["day_date"]),
                Index(name: "idx_sessions_status", unique: 0, partial: 0, columns: ["status"]),
            ])
        #expect(
            try indexes(f, "recordings") == [
                Index(name: "idx_recordings_session", unique: 0, partial: 0, columns: ["session_key"]),
                Index(name: "idx_recordings_sha", unique: 1, partial: 1, columns: ["sha256"]),
                Index(name: "idx_recordings_started", unique: 0, partial: 0, columns: ["started_at"]),
                Index(name: "idx_recordings_status", unique: 0, partial: 0, columns: ["status"]),
            ])
        #expect(
            try indexes(f, "events") == [
                Index(name: "idx_events_entity", unique: 0, partial: 0, columns: ["entity_type", "entity_key", "id"])
            ])
        #expect(try indexes(f, "imported_keys") == [])
    }

    @Test("recordings.session_key は sessions への外部キー（ON DELETE SET NULL）")
    func recordingsForeignKeyToSessions() throws {
        let f = try StoreFixture()
        let rows = try f.store.pool.writeWithoutTransaction { db in
            try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(recordings)")
        }
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(try row.decode(String.self, forColumn: "table") == "sessions")
        #expect(try row.decode(String.self, forColumn: "from") == "session_key")
        #expect(try row.decode(String.self, forColumn: "on_delete") == "SET NULL")
    }

    @Test("sha256 は NULL 以外で一意")
    func partialUniqueIndexOnSHA256() throws {
        let f = try StoreFixture()
        let a = try f.makeRecording(Builders.recording(relpath: StoreFixture.relpath("a")))
        let b = try f.makeRecording(Builders.recording(relpath: StoreFixture.relpath("b")))
        // 両方 NULL は可（2 行とも作れている）
        #expect(try f.int("SELECT COUNT(*) FROM recordings WHERE sha256 IS NULL") == 2)
        try f.store.updateRecording(a, [.sha256("x")])
        let error = #expect(throws: DatabaseError.self) {
            try f.store.updateRecording(b, [.sha256("x")])
        }
        #expect(error?.resultCode == .SQLITE_CONSTRAINT)
        #expect(try f.string("SELECT sha256 FROM recordings WHERE partkey = ?", [b]) == nil)
    }
}
