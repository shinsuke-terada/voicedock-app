// SQLite（GRDB DatabasePool・WAL）の開設とマイグレーション（PLAN §7.1 / §7.2）。
import Foundation
import GRDB
import VDCore

public final class Store: Sendable {
    let pool: DatabasePool
    let clock: any AppClock
    let zone: ZonedTime
    let url: URL

    static let busyTimeoutMilliseconds = 10_000
    static let recoveryDetail = "recovery"

    public convenience init(url: URL, clock: any AppClock, zone: ZonedTime) throws(StoreError) {
        try self.init(url: url, clock: clock, zone: zone, migrator: Schema.migrator())
    }

    /// テスト用（@testable）。移行器を差し替えてバックアップの条件を試す
    init(url: URL, clock: any AppClock, zone: ZonedTime, migrator: DatabaseMigrator) throws(StoreError) {
        // 1. 接続ごとの PRAGMA（PLAN §7.1）
        var config = Configuration()
        config.label = "VoiceDock"
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(10)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA busy_timeout = 10000")
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }

        // 2. プールを開く
        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: url.path(percentEncoded: false), configuration: config)
        } catch {
            let description = String(describing: error)
            if description.contains("could not activate WAL Mode") {
                throw .notWAL
            }
            throw .open(description)
        }

        // 3. WAL の確認と synchronous = FULL の設定し直し（GRDB は writer で NORMAL にする。§2.1）
        do {
            try pool.writeWithoutTransaction { db in
                let mode = try String.fetchOne(db, sql: "PRAGMA journal_mode")
                guard mode?.lowercased() == "wal" else { throw StoreError.notWAL }
                try db.execute(sql: "PRAGMA synchronous = FULL")
                let sync = try Int.fetchOne(db, sql: "PRAGMA synchronous")
                guard sync == 2 else { throw StoreError.open("synchronous is not FULL") }
            }
        } catch let error as StoreError {
            throw error
        } catch {
            throw .open(String(describing: error))
        }

        // 4. 移行の状態を読む
        let applied: [String]
        let superseded: Bool
        let completed: Bool
        do {
            (applied, superseded, completed) = try pool.read { db in
                (
                    try migrator.appliedMigrations(db), try migrator.hasBeenSuperseded(db),
                    try migrator.hasCompletedMigrations(db)
                )
            }
        } catch {
            throw .migration(String(describing: error))
        }

        // 5. より新しいアプリが当てた版がある。書かない
        if superseded {
            throw .migration("superseded")
        }

        // 6. 既存の DB に未適用があるときだけバックアップ（初回作成ではしない。CONC-04）
        if !completed && !applied.isEmpty {
            guard let last = applied.last else { throw .migration("no applied migration") }
            try Self.backup(pool: pool, url: url, last: last, stamp: zone.iso(clock.now()))
        }

        // 7. 移行を当てる
        do {
            try migrator.migrate(pool)
        } catch {
            throw .migration(String(describing: error))
        }

        // 8. 保持する
        self.pool = pool
        self.clock = clock
        self.zone = zone
        self.url = url
    }

    /// `Schema.migrator()` に登録した識別子の並び（DR-02 が最新かどうかを判定する。T-32）
    public static let migrationIdentifiers: [String] = Schema.migrator().migrations

    public var appliedMigrations: [String] {
        get throws { try pool.read { try Schema.migrator().appliedMigrations($0) } }
    }

    public func quickCheck() throws -> String {
        try pool.read { try String.fetchOne($0, sql: "PRAGMA quick_check") ?? "" }
    }

    /// 現在時刻の ISO 文字列（呼ぶたびに取る。TIME-04）
    func nowISO() -> String { zone.iso(clock.now()) }

    /// `<名前>.backup-<last>-<stamp>` を同じディレクトリに SQLite の backup API で作る（ファイルコピーは禁止。CONC-04）。
    /// stamp は ISO 文字列から ":" と "-" を取り除いたもの（voicedock db.py:287-289）
    private static func backup(pool: DatabasePool, url: URL, last: String, stamp iso: String) throws(StoreError) {
        let stamp = iso.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        let name = url.lastPathComponent + ".backup-" + last + "-" + stamp
        let backupURL = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            let destination = try DatabaseQueue(path: backupURL.path(percentEncoded: false))
            try pool.backup(to: destination)
        } catch {
            throw .backup(String(describing: error))
        }
    }
}
