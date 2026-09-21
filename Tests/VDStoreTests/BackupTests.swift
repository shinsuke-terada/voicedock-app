// 移行前のバックアップ（PLAN §7.2・CONC-04）。DB は TempDirectory の中だけに作る。
import Foundation
import GRDB
import TestSupport
import Testing
import VDCore

@testable import VDStore

@Suite("移行前のバックアップ")
struct BackupTests {
    static let backupName = "voicedock.sqlite.backup-v1_initial-20260830T070012+0900"

    /// v1_initial と v2_test（`CREATE TABLE t (x)`）を登録した移行器
    static func v2Migrator() -> DatabaseMigrator {
        var migrator = Schema.migrator()
        migrator.registerMigration("v2_test") { db in
            try db.execute(sql: "CREATE TABLE t (x)")
        }
        return migrator
    }

    static func zone() throws -> ZonedTime {
        ZonedTime(timeZone: try #require(TimeZone(identifier: "Asia/Tokyo")))
    }

    @Test("初回作成ではバックアップしない")
    func noBackupOnFirstCreation() throws {
        let f = try StoreFixture()
        #expect(try f.backupFiles().isEmpty)
    }

    @Test("未適用が無ければバックアップしない")
    func noBackupWhenUpToDate() throws {
        let f = try StoreFixture()
        _ = try f.reopen()
        #expect(try f.backupFiles().isEmpty)
    }

    @Test("既存 DB に未適用があるとき当てる前にバックアップする")
    func backupBeforePendingMigration() throws {
        let dir = try TempDirectory()
        let clock = FixedClock(epochMillis: StoreFixture.nowMillis)
        let url = dir.url.appendingPathComponent("voicedock.sqlite")
        do {
            let v1 = try Builders.openStore(in: dir.url, clock: clock)
            try v1.insertRecording(Builders.recording())
        }
        let v2 = try Store(url: url, clock: clock, zone: Self.zone(), migrator: Self.v2Migrator())
        #expect(try v2.appliedMigrations == ["v1_initial"])  // Schema.migrator() に v2_test は無い
        let backupURL = dir.url.appendingPathComponent(Self.backupName)
        #expect(FileManager.default.fileExists(atPath: backupURL.path(percentEncoded: false)))
        let backup = try DatabaseQueue(path: backupURL.path(percentEncoded: false))
        let (identifiers, count, hasT) = try backup.read { db in
            (
                try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recordings"), try db.tableExists("t")
            )
        }
        #expect(identifiers == ["v1_initial"])
        #expect(count == 1)
        #expect(hasT == false)
        let migrated = try v2.pool.read { db in try db.tableExists("t") }
        #expect(migrated)
    }

    @Test("バックアップは WAL の未反映分も含む（ファイルコピーではない）")
    func backupIncludesUncheckpointedWAL() throws {
        let dir = try TempDirectory()
        let clock = FixedClock(epochMillis: StoreFixture.nowMillis)
        let url = dir.url.appendingPathComponent("voicedock.sqlite")
        let first = try Builders.openStore(in: dir.url, clock: clock)
        try first.insertRecording(Builders.recording())
        let second = try Store(url: url, clock: clock, zone: Self.zone(), migrator: Self.v2Migrator())
        let backupURL = dir.url.appendingPathComponent(Self.backupName)
        let backup = try DatabaseQueue(path: backupURL.path(percentEncoded: false))
        let partkeys = try backup.read { db in try String.fetchAll(db, sql: "SELECT partkey FROM recordings") }
        #expect(partkeys == ["DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"])
        #expect(try first.recording(partkeys.first ?? "") != nil)
        #expect(try second.quickCheck() == "ok")
    }
}
