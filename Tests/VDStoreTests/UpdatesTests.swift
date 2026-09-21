// status 以外の列の更新（PLAN §5.2）。期待値は §4.7 の列の対応表から写した。
import Foundation
import GRDB
import TestSupport
import Testing
import VDCore

@testable import VDStore

@Suite("列の更新")
struct UpdatesTests {
    @Test("列を書き updated_at を進める")
    func updateRecordingSetsColumnsAndUpdatedAt() throws {
        let f = try StoreFixture(stepping: true)
        let key = try f.makeRecording(Builders.recording())
        #expect(try f.store.recording(key)?.updatedAt == "2026-08-30T07:00:12+09:00")
        try f.store.updateRecording(key, [.sha256("s"), .transcriptPath("t")])
        let row = try #require(try f.store.recording(key))
        #expect(row.sha256 == "s")
        #expect(row.transcriptPath == "t")
        #expect(row.updatedAt == "2026-08-30T07:00:13+09:00")
        #expect(row.status == .discovered)
        #expect(try f.eventCount() == 1)
    }

    @Test("空の更新は updated_at も変えない")
    func emptyUpdateTouchesNothing() throws {
        let f = try StoreFixture(stepping: true)
        let key = try f.makeRecording(Builders.recording())
        try f.store.updateRecording(key, [])
        try f.store.insertSession(Builders.session())
        try f.store.updateSession("DJIMIC3:20260829", [])
        #expect(try f.store.recording(key)?.updatedAt == "2026-08-30T07:00:12+09:00")
        #expect(try f.store.session("DJIMIC3:20260829")?.updatedAt == "2026-08-30T07:00:13+09:00")
    }

    @Test("どの RecordingField も status 以外の列を書く")
    func allRecordingFieldsMapToNonStatusColumns() throws {
        let f = try StoreFixture()
        try f.store.insertSession(Builders.session())
        let key = try f.makeRecording(Builders.recording())
        let samples: [(RecordingField, String, DatabaseValue)] = [
            (.sessionKey("DJIMIC3:20260829"), "session_key", "DJIMIC3:20260829".databaseValue),
            (.durationSeconds(12.5), "duration_seconds", 12.5.databaseValue),
            (.endedAt("e"), "ended_at", "e".databaseValue),
            (.sha256("s"), "sha256", "s".databaseValue),
            (.sha256Helper("h"), "sha256_helper", "h".databaseValue),
            (.inboxPath("i"), "inbox_path", "i".databaseValue),
            (.stagingDir("d"), "staging_dir", "d".databaseValue),
            (.normalizedPath("n"), "normalized_path", "n".databaseValue),
            (.transcriptPath("t"), "transcript_path", "t".databaseValue),
            (.sourceSize(7), "source_size", 7.databaseValue),
            (.sourceMtime(1.5), "source_mtime", 1.5.databaseValue),
            (.errorCode(.whisperFailed), "error_code", "WHISPER_FAILED".databaseValue),
            (.errorMessage("m"), "error_message", "m".databaseValue),
            (.sourceDeletedAt("x"), "source_deleted_at", "x".databaseValue),
            (.deleteRequestID("r"), "delete_request_id", "r".databaseValue),
            (.duplicateOf("o"), "duplicate_of", "o".databaseValue),
            (.needsRecopy(true), "needs_recopy", 1.databaseValue),
        ]
        #expect(Set(samples.map(\.1)).count == 17)
        for (field, column, expected) in samples {
            try f.store.updateRecording(key, [field])
            let actual = try f.value("SELECT \(column) FROM recordings WHERE partkey = ?", [key])
            #expect(actual == expected, "\(column)")
            #expect(try f.store.recording(key)?.status == .discovered)
        }
        // nil は NULL
        try f.store.updateRecording(key, [.sha256(nil), .errorCode(nil), .errorMessage(nil)])
        #expect(try f.value("SELECT sha256 FROM recordings WHERE partkey = ?", [key]) == .null)
        #expect(try f.value("SELECT error_code FROM recordings WHERE partkey = ?", [key]) == .null)
        #expect(try f.value("SELECT error_message FROM recordings WHERE partkey = ?", [key]) == .null)
    }

    @Test("どの SessionField も status 以外の列を書く")
    func allSessionFieldsMapToNonStatusColumns() throws {
        let f = try StoreFixture()
        let key = "DJIMIC3:20260829"
        try f.store.insertSession(Builders.session())
        let samples: [(SessionField, String, DatabaseValue)] = [
            (.startedAt("a"), "started_at", "a".databaseValue),
            (.endedAt("b"), "ended_at", "b".databaseValue),
            (.recordedSeconds(12.5), "recorded_seconds", 12.5.databaseValue),
            (.partCount(3), "part_count", 3.databaseValue),
            (.failedPartCount(1), "failed_part_count", 1.databaseValue),
            (.title("t"), "title", "t".databaseValue),
            (.analysisPath("p"), "analysis_path", "p".databaseValue),
            (.rawOutputPath("r"), "raw_output_path", "r".databaseValue),
            (.rawOutputSHA256("rs"), "raw_output_sha256", "rs".databaseValue),
            (.outputPath("o"), "output_path", "o".databaseValue),
            (.outputSHA256("os"), "output_sha256", "os".databaseValue),
            (.regeneratedCount(2), "regenerated_count", 2.databaseValue),
            (.deleteAttempts(4), "delete_attempts", 4.databaseValue),
            (.errorCode(.whisperFailed), "error_code", "WHISPER_FAILED".databaseValue),
            (.errorMessage("m"), "error_message", "m".databaseValue),
            (.sourceDeletedAt("x"), "source_deleted_at", "x".databaseValue),
        ]
        #expect(Set(samples.map(\.1)).count == 16)
        for (field, column, expected) in samples {
            try f.store.updateSession(key, [field])
            let actual = try f.value("SELECT \(column) FROM sessions WHERE session_key = ?", [key])
            #expect(actual == expected, "\(column)")
            #expect(try f.store.session(key)?.status == .open)
        }
    }

    @Test("同じ列を 2 回渡すと invalidUpdate")
    func duplicateColumnIsRejected() throws {
        let f = try StoreFixture(stepping: true)
        let key = try f.makeRecording(Builders.recording())
        #expect(throws: StoreError.invalidUpdate("sha256")) {
            try f.store.updateRecording(key, [.sha256("a"), .sha256("b")])
        }
        let row = try #require(try f.store.recording(key))
        #expect(row.sha256 == nil)
        #expect(row.updatedAt == "2026-08-30T07:00:12+09:00")
        try f.store.insertSession(Builders.session())
        #expect(throws: StoreError.invalidUpdate("title")) {
            try f.store.updateSession("DJIMIC3:20260829", [.title("a"), .title("b")])
        }
        #expect(try f.store.session("DJIMIC3:20260829")?.title == nil)
    }

    @Test("列更新でも error_message を切り詰める")
    func errorMessageIsTruncatedOnUpdate() throws {
        let f = try StoreFixture()
        let key = try f.makeRecording(Builders.recording())
        try f.store.updateRecording(key, [.errorMessage(String(repeating: "a", count: 201))])
        let stored = try #require(try f.store.recording(key)?.errorMessage)
        #expect(stored.unicodeScalars.count == 200)
        #expect(stored == String(repeating: "a", count: 199) + "\u{2026}")
    }

    @Test("needs_recopy は 0 / 1 で保存する")
    func needsRecopyIsInteger() throws {
        let f = try StoreFixture()
        let key = try f.makeRecording(Builders.recording())
        try f.store.updateRecording(key, [.needsRecopy(true)])
        #expect(try f.value("SELECT needs_recopy FROM recordings WHERE partkey = ?", [key]) == 1.databaseValue)
        try f.store.updateRecording(key, [.needsRecopy(false)])
        #expect(try f.value("SELECT needs_recopy FROM recordings WHERE partkey = ?", [key]) == 0.databaseValue)
    }

    @Test("行が無くても例外にしない")
    func missingRowIsIgnored() throws {
        let f = try StoreFixture()
        try f.store.updateRecording("DJIMIC3/none.wav", [.sha256("x")])
        try f.store.updateSession("DJIMIC3:20990101", [.title("x")])
        #expect(try f.int("SELECT COUNT(*) FROM recordings") == 0)
    }
}
