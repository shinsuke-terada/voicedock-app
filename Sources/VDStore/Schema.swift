// v1_initial の DDL（PLAN §7.2 の逐語）と DatabaseMigrator。
import GRDB

enum Schema {
    static let v1InitialIdentifier = "v1_initial"
    static let v1Initial: String = """
        CREATE TABLE sessions (
            session_key         TEXT    PRIMARY KEY NOT NULL,
            day_date            TEXT    NOT NULL,
            device_id           TEXT    NOT NULL,
            started_at          TEXT,
            ended_at            TEXT,
            recorded_seconds    REAL,
            part_count          INTEGER NOT NULL DEFAULT 0,
            failed_part_count   INTEGER NOT NULL DEFAULT 0,
            title               TEXT,
            analysis_path       TEXT,
            raw_output_path     TEXT,
            raw_output_sha256   TEXT,
            output_path         TEXT,
            output_sha256       TEXT,
            status              TEXT    NOT NULL,
            retry_count         INTEGER NOT NULL DEFAULT 0,
            regenerated_count   INTEGER NOT NULL DEFAULT 0,
            delete_attempts     INTEGER NOT NULL DEFAULT 0,
            error_code          TEXT,
            error_message       TEXT,
            source_deleted_at   TEXT,
            updated_at          TEXT    NOT NULL
        );
        CREATE INDEX idx_sessions_status ON sessions (status);
        CREATE INDEX idx_sessions_day    ON sessions (day_date);

        CREATE TABLE recordings (
            partkey               TEXT    PRIMARY KEY NOT NULL,
            device_id             TEXT    NOT NULL,
            source_folder         TEXT    NOT NULL,
            transmitter_id        TEXT    NOT NULL,
            mic_index             INTEGER NOT NULL,
            started_at            TEXT    NOT NULL,
            duration_seconds      REAL,
            ended_at              TEXT,
            source_path           TEXT,
            source_size           INTEGER,
            source_mtime          REAL,
            sha256                TEXT,
            sha256_helper         TEXT,
            inbox_path            TEXT,
            staging_dir           TEXT,
            normalized_path       TEXT,
            transcript_path       TEXT,
            session_key           TEXT REFERENCES sessions(session_key) ON DELETE SET NULL,
            status                TEXT    NOT NULL,
            retry_count           INTEGER NOT NULL DEFAULT 0,
            error_code            TEXT,
            error_message         TEXT,
            source_deleted_at     TEXT,
            updated_at            TEXT    NOT NULL,
            delete_request_id     TEXT,
            duplicate_of          TEXT,
            needs_recopy          INTEGER NOT NULL DEFAULT 0
        );
        CREATE UNIQUE INDEX idx_recordings_sha ON recordings (sha256) WHERE sha256 IS NOT NULL;
        CREATE INDEX idx_recordings_status   ON recordings (status);
        CREATE INDEX idx_recordings_session  ON recordings (session_key);
        CREATE INDEX idx_recordings_started  ON recordings (started_at);

        CREATE TABLE events (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            entity_type   TEXT NOT NULL,
            entity_key    TEXT NOT NULL,
            from_status   TEXT,
            to_status     TEXT NOT NULL,
            error_code    TEXT,
            detail        TEXT,
            created_at    TEXT NOT NULL
        );
        CREATE INDEX idx_events_entity ON events (entity_type, entity_key, id);

        CREATE TABLE imported_keys (
            partkey      TEXT PRIMARY KEY NOT NULL,
            source_note  TEXT NOT NULL,
            imported_at  TEXT NOT NULL
        );
        """
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(v1InitialIdentifier) { db in
            try db.execute(sql: v1Initial)
        }
        return migrator
    }
}
