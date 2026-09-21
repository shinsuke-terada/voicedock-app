// 読み取り専用の経路（PLAN §7.1・CONC-06）。DB は TempDirectory の中だけに作る。
import Foundation
import GRDB
import TestSupport
import Testing
import VDCore

@testable import VDStore

@Suite("読み取り専用")
struct ReadOnlyStoreTests {
    @Test("DB が無ければ nil で、ファイルを何も作らない")
    func missingDatabaseReturnsNilAndCreatesNothing() throws {
        let dir = try TempDirectory()
        let url = dir.url.appendingPathComponent("voicedock.sqlite")
        #expect(ReadOnlyStore.open(url: url) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path(percentEncoded: false)).isEmpty)
    }

    @Test("読み取り専用で書けない")
    func cannotWrite() throws {
        let f = try StoreFixture()
        let ro = try #require(ReadOnlyStore.open(url: f.databaseURL))
        let error = #expect(throws: DatabaseError.self) {
            try ro.queue.write { db in
                try db.execute(
                    sql: "INSERT INTO imported_keys (partkey, source_note, imported_at) VALUES (?, ?, ?)",
                    arguments: ["k", "n", "t"])
            }
        }
        #expect(error?.resultCode == .SQLITE_READONLY)
        #expect(try f.store.importedKeys().isEmpty)
    }

    @Test("状態別件数は全状態を 0 で埋める")
    func statusCountsAreZeroFilled() throws {
        let f = try StoreFixture()
        try f.makeRecording(Builders.recording(relpath: StoreFixture.relpath("a")))
        try f.makeRecording(Builders.recording(relpath: StoreFixture.relpath("b")), path: [.skipped])
        try f.store.insertSession(Builders.session(key: "DJIMIC3:20260829"))
        try f.store.insertSession(Builders.session(key: "DJIMIC3:20260830"))
        try f.walkSession("DJIMIC3:20260830", from: .open, through: [.ready])
        let ro = try #require(ReadOnlyStore.open(url: f.databaseURL))
        let counts = try ro.statusCounts()
        #expect(counts.parts.count == 12)
        #expect(counts.sessions.count == 13)
        for status in PartStatus.allCases {
            #expect(counts.parts[status] == ([.discovered, .skipped].contains(status) ? 1 : 0), "\(status)")
        }
        for status in SessionStatus.allCases {
            #expect(counts.sessions[status] == ([.open, .ready].contains(status) ? 1 : 0), "\(status)")
        }
    }

    @Test("未処理は非終端の件数・長さの合計・長さ不明の件数")
    func backlogCountsNullDurations() throws {
        let f = try StoreFixture()
        try f.makeRecording(Builders.recording(relpath: StoreFixture.relpath("a"), durationSeconds: 100))
        try f.makeRecording(
            Builders.recording(relpath: StoreFixture.relpath("b"), durationSeconds: nil), path: [.normalizing])
        try f.makeRecording(
            Builders.recording(relpath: StoreFixture.relpath("c"), durationSeconds: 50),
            path: [.normalizing, .normalized])
        try f.makeRecording(
            Builders.recording(relpath: StoreFixture.relpath("d"), durationSeconds: 1800),
            path: [.normalizing, .failed])
        let ro = try #require(ReadOnlyStore.open(url: f.databaseURL))
        let backlog = try ro.backlog()
        #expect(backlog.count == 3)
        #expect(backlog.seconds == 150.0)
        #expect(backlog.unknownDuration == 1)
    }

    @Test("FAILED の一覧は started_at 順・上限・総数")
    func failedPartsLimitAndTotal() throws {
        let f = try StoreFixture()
        // 遅い started_at から作る（作った順と started_at の順を逆にする）
        for index in (0..<25).reversed() {
            let started = String(format: "2026-08-29T07:%02d:00+09:00", index)
            try f.makeRecording(
                Builders.recording(relpath: StoreFixture.relpath(String(format: "f%02d", index)), startedAt: started),
                path: [.normalizing, .failed])
        }
        try f.makeRecording(Builders.recording(relpath: StoreFixture.relpath("ok")))
        let ro = try #require(ReadOnlyStore.open(url: f.databaseURL))
        let failed = try ro.failedParts(limit: 20)
        #expect(failed.rows.count == 20)
        #expect(failed.total == 25)
        #expect(failed.rows.first?.startedAt == "2026-08-29T07:00:00+09:00")
        #expect(failed.rows.last?.startedAt == "2026-08-29T07:19:00+09:00")
        #expect(failed.rows.allSatisfy { $0.status == .failed })
    }

    @Test("適用済みの移行を読める")
    func appliedMigrationsReadOnly() throws {
        let f = try StoreFixture()
        let ro = try #require(ReadOnlyStore.open(url: f.databaseURL))
        #expect(try ro.appliedMigrations() == ["v1_initial"])
        #expect(try ro.quickCheck() == "ok")
    }

    @Test("結果待ちの数と状態別の partkey を読める")
    func awaitingDeleteResultCountAndPartkeys() throws {
        let f = try StoreFixture()
        let c = try f.makeRecording(Builders.recording(relpath: StoreFixture.relpath("c")))
        let a = try f.makeRecording(Builders.recording(relpath: StoreFixture.relpath("a")))
        try f.makeRecording(Builders.recording(relpath: StoreFixture.relpath("b")))
        try f.store.updateRecording(c, [.deleteRequestID("r")])
        try f.store.updateRecording(a, [.deleteRequestID("r")])
        let ro = try #require(ReadOnlyStore.open(url: f.databaseURL))
        #expect(try ro.awaitingDeleteResultCount() == 2)
        #expect(
            try ro.partkeys(statuses: [.discovered]) == [
                "DJIMIC3/TX_MIC001_20260829_071201/a.wav", "DJIMIC3/TX_MIC001_20260829_071201/b.wav",
                "DJIMIC3/TX_MIC001_20260829_071201/c.wav",
            ])
        #expect(try ro.partkeys(statuses: [.failed]) == [])
    }
}
