// 分組の 1 件を 1 トランザクションで行う Store.groupPart（PLAN §5.6。F-82・issue #119 の D6）。期待値は仕様の固定値。
import Foundation
import GRDB
import TestSupport
import Testing
import VDCore

@testable import VDStore

@Suite("Store.groupPart（F-82 分組の 1 トランザクション）")
struct GroupPartTests {
    static let sessionKey = "DJIMIC3:20260829"

    /// session の events の (from, to, detail) の並び
    static func sessionEvents(_ f: StoreFixture) throws -> [(String?, String, String?)] {
        try f.store.events(entity: .session, key: sessionKey).map { ($0.fromStatus, $0.toStatus, $0.detail) }
    }

    @Test("F-82 Session が無ければ作り、session_key・集計・NULL→OPEN・OPEN→OPEN（detail = partkey）を書いて OPEN を返す")
    func createsSessionAndRecordsOpenToOpen() throws {
        let f = try StoreFixture()
        let pk = try f.makeRecording(Builders.recording())

        let status = try f.store.groupPart(pk, into: Builders.session())

        #expect(status == .open)
        #expect(try f.store.recording(pk)?.sessionKey == Self.sessionKey)
        let s = try #require(try f.store.session(Self.sessionKey))
        #expect(s.status == .open)
        #expect(s.partCount == 1)
        #expect(s.startedAt == "2026-08-29T07:12:04+09:00")
        #expect(s.endedAt == "2026-08-29T07:42:04+09:00")
        #expect(s.recordedSeconds == 1800)
        #expect(s.failedPartCount == 0)
        let events = try Self.sessionEvents(f)
        #expect(events.count == 2)
        #expect(events.first?.0 == nil)
        #expect(events.first?.1 == "OPEN")
        #expect(events.first?.2 == nil)
        #expect(events.last?.0 == "OPEN")
        #expect(events.last?.1 == "OPEN")
        #expect(events.last?.2 == pk)
    }

    @Test("F-82 既にある OPEN の Session には 2 本目も同じトランザクションで集計に入り、OPEN→OPEN を Part ごとに書く")
    func secondPartJoinsAggregates() throws {
        let f = try StoreFixture()
        let p1 = try f.makeRecording(
            Builders.recording(
                relpath: StoreFixture.relpath("p1"), startedAt: "2026-08-29T07:00:00+09:00", durationSeconds: 100))
        let p2 = try f.makeRecording(
            Builders.recording(
                relpath: StoreFixture.relpath("p2"), startedAt: "2026-08-29T07:10:00+09:00", durationSeconds: 50))

        #expect(try f.store.groupPart(p1, into: Builders.session()) == .open)
        #expect(try f.store.groupPart(p2, into: Builders.session()) == .open)

        let s = try #require(try f.store.session(Self.sessionKey))
        #expect(s.partCount == 2)
        #expect(s.startedAt == "2026-08-29T07:00:00+09:00")
        #expect(s.endedAt == "2026-08-29T07:10:50+09:00")
        #expect(s.recordedSeconds == 150)
        let details = try Self.sessionEvents(f).map(\.2)
        #expect(details == [nil, p1, p2])
    }

    @Test("F-82 閉じた Session への追加は events を書かず、集計だけ数え直してその状態を返す")
    func closedSessionGetsNoEvents() throws {
        let f = try StoreFixture()
        try f.store.insertSession(Builders.session())
        for (from, to) in [(SessionStatus.open, SessionStatus.ready), (.ready, .merging), (.merging, .completed)] {
            try f.store.recordSessionTransition(sessionKey: Self.sessionKey, from: from, to: to)
        }
        let before = try Self.sessionEvents(f).count
        let pk = try f.makeRecording(Builders.recording(), path: [.normalizing, .failed])

        let status = try f.store.groupPart(pk, into: Builders.session())

        #expect(status == .completed)
        #expect(try Self.sessionEvents(f).count == before)
        let s = try #require(try f.store.session(Self.sessionKey))
        #expect(s.status == .completed)
        #expect(s.partCount == 1)
        #expect(s.failedPartCount == 1)
        #expect(try f.store.recording(pk)?.sessionKey == Self.sessionKey)
    }

    @Test("F-82 TEST-28 行の無い partkey（空文字）では Session も events も作らず nil")
    func missingPartWritesNothing() throws {
        let f = try StoreFixture()

        #expect(try f.store.groupPart("", into: Builders.session()) == nil)

        #expect(try f.store.session(Self.sessionKey) == nil)
        #expect(try f.eventCount() == 0)
    }

    @Test("F-82 途中（OPEN→OPEN の events）で失敗したら、Session の作成も session_key も集計も残さない")
    func failureRollsBackEverything() throws {
        let f = try StoreFixture(stepping: true)
        let pk = try f.makeRecording(Builders.recording())
        let updatedAt = try #require(try f.store.recording(pk)?.updatedAt)
        try f.store.pool.write { db in
            try db.execute(
                sql: "CREATE TRIGGER f82_abort BEFORE INSERT ON events "
                    + "WHEN NEW.entity_type = 'session' AND NEW.from_status = 'OPEN' AND NEW.to_status = 'OPEN' "
                    + "BEGIN SELECT RAISE(ABORT, 'f82'); END")
        }

        #expect(throws: (any Error).self) { try f.store.groupPart(pk, into: Builders.session()) }

        #expect(try f.store.session(Self.sessionKey) == nil)
        #expect(try Self.sessionEvents(f).isEmpty)
        let row = try #require(try f.store.recording(pk))
        #expect(row.sessionKey == nil)
        #expect(row.updatedAt == updatedAt)
        #expect(try f.store.ungroupedRecordings().map(\.partkey) == [pk])
    }
}
