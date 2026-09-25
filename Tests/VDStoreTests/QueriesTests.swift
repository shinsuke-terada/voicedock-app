// 問い合わせ（PLAN §5.3・§5.6・§7.2）。並び順の期待値は仕様の ORDER BY から手で書いた。
import Foundation
import GRDB
import TestSupport
import Testing
import VDCore

@testable import VDStore

@Suite("問い合わせ")
struct QueriesTests {
    /// partkey と started_at をわざと逆順に 3 行（p3 が 08:00、p2 と p1 が 07:00 で同じ）作る。期待の順は p1, p2, p3
    func makeReversed(_ f: StoreFixture) throws -> [String] {
        let p3 = try f.makeRecording(
            Builders.recording(relpath: StoreFixture.relpath("p3"), startedAt: "2026-08-29T08:00:00+09:00"))
        let p2 = try f.makeRecording(
            Builders.recording(relpath: StoreFixture.relpath("p2"), startedAt: "2026-08-29T07:00:00+09:00"))
        let p1 = try f.makeRecording(
            Builders.recording(relpath: StoreFixture.relpath("p1"), startedAt: "2026-08-29T07:00:00+09:00"))
        return [p1, p2, p3]
    }

    @Test("未分組は started_at, partkey 順")
    func ungroupedOrderedByStartedAtThenPartkey() throws {
        let f = try StoreFixture()
        let expected = try makeReversed(f)
        #expect(
            try f.store.ungroupedRecordings().map(\.partkey) == [
                "DJIMIC3/TX_MIC001_20260829_071201/p1.wav", "DJIMIC3/TX_MIC001_20260829_071201/p2.wav",
                "DJIMIC3/TX_MIC001_20260829_071201/p3.wav",
            ])
        #expect(expected.count == 3)
    }

    @Test("Session の Part は started_at, partkey 順")
    func sessionPartsOrdered() throws {
        let f = try StoreFixture()
        try f.store.insertSession(Builders.session())
        let keys = try makeReversed(f)
        for key in keys.reversed() {
            try f.store.updateRecording(key, [.sessionKey("DJIMIC3:20260829")])
        }
        #expect(
            try f.store.recordings(inSession: "DJIMIC3:20260829").map(\.partkey) == [
                "DJIMIC3/TX_MIC001_20260829_071201/p1.wav", "DJIMIC3/TX_MIC001_20260829_071201/p2.wav",
                "DJIMIC3/TX_MIC001_20260829_071201/p3.wav",
            ])
        #expect(try f.store.ungroupedRecordings().isEmpty)
    }

    @Test("状態別も同じ順")
    func recordingsByStatusOrdered() throws {
        let f = try StoreFixture()
        _ = try makeReversed(f)
        #expect(
            try f.store.recordings(status: .discovered).map(\.partkey) == [
                "DJIMIC3/TX_MIC001_20260829_071201/p1.wav", "DJIMIC3/TX_MIC001_20260829_071201/p2.wav",
                "DJIMIC3/TX_MIC001_20260829_071201/p3.wav",
            ])
        #expect(try f.store.recordings(status: .failed).isEmpty)
    }

    @Test("Session の状態別は session_key 順")
    func sessionsByStatusOrderedByKey() throws {
        let f = try StoreFixture()
        for key in ["DJIMIC3:20260830", "DJIMIC3:20260829#2", "DJIMIC3:20260829"] {
            try f.store.insertSession(Builders.session(key: key))
        }
        #expect(
            try f.store.sessions(status: .open).map(\.sessionKey) == [
                "DJIMIC3:20260829", "DJIMIC3:20260829#2", "DJIMIC3:20260830",
            ])
    }

    @Test("非終端は終端 6 状態を除く")
    func nonTerminalExcludesSixTerminalStates() throws {
        let f = try StoreFixture()
        // 12 状態のそれぞれに 1 行。started_at は宣言順に 1 分ずつ遅らせる
        let states: [(String, PartStatus)] = [
            ("s01", .discovered), ("s02", .normalizing), ("s03", .normalized), ("s04", .transcribing),
            ("s05", .transcribed), ("s06", .rawWriting), ("s07", .rawSaved), ("s08", .sourceDeleting),
            ("s09", .sourceDeletePending), ("s10", .completed), ("s11", .failed), ("s12", .skipped),
        ]
        for (index, (name, status)) in states.enumerated() {
            let started = String(format: "2026-08-29T07:%02d:00+09:00", index)
            try f.makeRecording(
                Builders.recording(relpath: StoreFixture.relpath(name), startedAt: started),
                path: StoreFixture.path(to: status))
        }
        #expect(
            try f.store.nonTerminalPartkeys() == [
                "DJIMIC3/TX_MIC001_20260829_071201/s01.wav", "DJIMIC3/TX_MIC001_20260829_071201/s02.wav",
                "DJIMIC3/TX_MIC001_20260829_071201/s03.wav", "DJIMIC3/TX_MIC001_20260829_071201/s04.wav",
                "DJIMIC3/TX_MIC001_20260829_071201/s05.wav", "DJIMIC3/TX_MIC001_20260829_071201/s06.wav",
            ])
    }

    @Test("FAILED の一覧は updated_at, key 順")
    func failedKeysOrderedByUpdatedAt() throws {
        let f = try StoreFixture(stepping: true)
        let a = try f.makeRecording(Builders.recording(relpath: StoreFixture.relpath("a")), path: [.normalizing])
        let b = try f.makeRecording(Builders.recording(relpath: StoreFixture.relpath("b")), path: [.normalizing])
        let c = try f.makeRecording(Builders.recording(relpath: StoreFixture.relpath("c")), path: [.normalizing])
        for key in [b, c, a] {
            try f.store.recordPartTransition(partkey: key, from: .normalizing, to: .failed)
        }
        #expect(
            try f.store.failedRecordingKeys() == [
                "DJIMIC3/TX_MIC001_20260829_071201/b.wav", "DJIMIC3/TX_MIC001_20260829_071201/c.wav",
                "DJIMIC3/TX_MIC001_20260829_071201/a.wav",
            ])
        for key in ["DJIMIC3:20260831", "DJIMIC3:20260830", "DJIMIC3:20260829"] {
            try f.store.insertSession(Builders.session(key: key))
            try f.walkSession(key, from: .open, through: [.ready, .merging, .failed])
        }
        #expect(try f.store.failedSessionKeys() == ["DJIMIC3:20260831", "DJIMIC3:20260830", "DJIMIC3:20260829"])
    }

    @Test("戻り先は直近の FAILED の from")
    func failedFromIsLatestFailedEvent() throws {
        let f = try StoreFixture()
        let key = try f.makeRecording(
            Builders.recording(), path: [.normalizing, .failed, .normalizing, .normalized, .transcribing, .failed])
        #expect(try f.store.failedFromPart(key) == .transcribing)
        try f.store.insertSession(Builders.session())
        try f.walkSession("DJIMIC3:20260829", from: .open, through: [.ready, .merging, .merged, .analyzing, .failed])
        #expect(try f.store.failedFromSession("DJIMIC3:20260829") == .analyzing)
    }

    @Test("FAILED が無ければ nil")
    func failedFromNilWithoutFailure() throws {
        let f = try StoreFixture()
        let key = try f.makeRecording(Builders.recording(), path: [.normalizing])
        #expect(try f.store.failedFromPart(key) == nil)
        #expect(try f.store.failedFromPart("DJIMIC3/none.wav") == nil)
        #expect(try f.store.failedFromSession("DJIMIC3:20260829") == nil)
    }

    @Test("削除評価の Session は全件を updated_at, session_key 順")
    func deleteEvaluationOrderedByUpdatedAt() throws {
        let f = try StoreFixture(stepping: true)
        for key in ["DJIMIC3:20260829", "DJIMIC3:20260830", "DJIMIC3:20260831"] {
            try f.store.insertSession(Builders.session(key: key))
        }
        try f.walkSession("DJIMIC3:20260831", from: .open, through: [.ready])
        try f.walkSession("DJIMIC3:20260829", from: .open, through: [.ready, .merging])
        let rows = try f.store.sessionsForDeleteEvaluation()
        #expect(rows.map(\.sessionKey) == ["DJIMIC3:20260830", "DJIMIC3:20260831", "DJIMIC3:20260829"])
        #expect(rows.map(\.status) == [.open, .ready, .merging])
    }

    @Test("normalized_path で引く")
    func normalizedPathLookup() throws {
        let f = try StoreFixture()
        let key = try f.makeRecording(Builders.recording())
        try f.store.updateRecording(key, [.normalizedPath("staging/x.wav")])
        #expect(try f.store.recording(normalizedPath: "staging/x.wav")?.partkey == key)
        #expect(try f.store.recording(normalizedPath: "staging/y.wav") == nil)
    }

    @Test("sha256 で引く")
    func sha256Lookup() throws {
        let f = try StoreFixture()
        let key = try f.makeRecording(Builders.recording())
        try f.store.updateRecording(key, [.sha256("abc")])
        #expect(try f.store.recording(sha256: "abc")?.partkey == key)
        #expect(try f.store.recording(sha256: "def") == nil)
    }

    @Test("delete_request_id を持つ Part だけ")
    func awaitingDeleteResult() throws {
        let f = try StoreFixture()
        let a = try f.makeRecording(Builders.recording(relpath: StoreFixture.relpath("a")))
        try f.makeRecording(Builders.recording(relpath: StoreFixture.relpath("b")))
        try f.store.updateRecording(a, [.deleteRequestID("r")])
        #expect(try f.store.recordingsAwaitingDeleteResult().map(\.partkey) == [a])
    }

    @Test("needs_recopy = 1 の Part だけ")
    func needingRecopy() throws {
        let f = try StoreFixture()
        try f.makeRecording(Builders.recording(relpath: StoreFixture.relpath("a")))
        let b = try f.makeRecording(Builders.recording(relpath: StoreFixture.relpath("b")))
        try f.store.updateRecording(b, [.needsRecopy(true)])
        #expect(try f.store.recordingsNeedingRecopy().map(\.partkey) == [b])
    }

    @Test("状態の集合で partkey を引く（partkey 順）")
    func partkeysByStatuses() throws {
        let f = try StoreFixture()
        try f.makeRecording(Builders.recording(relpath: StoreFixture.relpath("d2")))
        try f.makeRecording(Builders.recording(relpath: StoreFixture.relpath("n1")), path: [.normalizing, .normalized])
        try f.makeRecording(Builders.recording(relpath: StoreFixture.relpath("f1")), path: [.normalizing, .failed])
        try f.makeRecording(Builders.recording(relpath: StoreFixture.relpath("d1")))
        #expect(
            try f.store.partkeys(statuses: [.discovered, .failed]) == [
                "DJIMIC3/TX_MIC001_20260829_071201/d1.wav", "DJIMIC3/TX_MIC001_20260829_071201/d2.wav",
                "DJIMIC3/TX_MIC001_20260829_071201/f1.wav",
            ])
        #expect(try f.store.partkeys(statuses: []) == [])
    }

    @Test("events は id 順")
    func eventsInIdOrder() throws {
        let f = try StoreFixture()
        let key = try f.makeRecording(Builders.recording(), path: [.normalizing, .normalized])
        let events = try f.store.events(entity: .recording, key: key)
        #expect(events.map(\.toStatus) == ["DISCOVERED", "NORMALIZING", "NORMALIZED"])
        #expect(events.map(\.id) == events.map(\.id).sorted())
        #expect(Set(events.map(\.id)).count == 3)
        #expect(try f.store.events(entity: .session, key: key).isEmpty)
    }

    @Test("未知の error_code は errorCode nil・errorCodeRaw に文字列のまま残る")
    func unknownErrorCodeKeepsRawString() throws {
        let f = try StoreFixture()
        let key = try f.makeRecording(Builders.recording())
        let nullRow = try #require(try f.store.recording(key))
        #expect(nullRow.errorCode == nil)
        #expect(nullRow.errorCodeRaw == nil)
        try f.store.pool.write { db in
            try db.execute(
                sql: "UPDATE recordings SET error_code = 'FUTURE_CODE_X' WHERE partkey = ?", arguments: [key])
        }
        let unknown = try #require(try f.store.recording(key))
        #expect(unknown.errorCode == nil)
        #expect(unknown.errorCodeRaw == "FUTURE_CODE_X")
        try f.store.updateRecording(key, [.errorCode(.whisperFailed)])
        let known = try #require(try f.store.recording(key))
        #expect(known.errorCode == .whisperFailed)
        #expect(known.errorCodeRaw == "WHISPER_FAILED")
    }

    @Test("500 件を超える問い合わせも正しい")
    func knownPartkeysChunks() throws {
        let f = try StoreFixture()
        var keys: [String] = []
        for index in 0..<1200 {
            keys.append(
                try f.makeRecording(Builders.recording(relpath: StoreFixture.relpath(String(format: "k%04d", index)))))
        }
        let query =
            keys + [
                "DJIMIC3/TX_MIC001_20260829_071201/none1.wav", "DJIMIC3/TX_MIC001_20260829_071201/none2.wav",
                "DJIMIC3/TX_MIC001_20260829_071201/none3.wav",
            ]
        let known = try f.store.knownPartkeys(query)
        #expect(known.count == 1200)
        #expect(known.contains("DJIMIC3/TX_MIC001_20260829_071201/k0000.wav"))
        #expect(known.contains("DJIMIC3/TX_MIC001_20260829_071201/k1199.wav"))
        #expect(!known.contains("DJIMIC3/TX_MIC001_20260829_071201/none1.wav"))
    }

    @Test("空の入力は空")
    func knownPartkeysEmpty() throws {
        let f = try StoreFixture()
        try f.makeRecording(Builders.recording())
        #expect(try f.store.knownPartkeys([]) == [])
    }

    @Test("取り込み済みの鍵は DB の行と重複を除いて入れる")
    func importedKeysSkipKnownAndDuplicates() throws {
        let f = try StoreFixture()
        let a = try f.makeRecording(Builders.recording(relpath: StoreFixture.relpath("a")))
        let b = "DJIMIC3/TX_MIC001_20260829_071201/b.wav"
        let c = "DJIMIC3/TX_MIC001_20260829_071201/c.wav"
        #expect(try f.store.insertImportedKeys([(partkey: b, sourceNote: "Raw/b.md")]) == 1)
        let added = try f.store.insertImportedKeys([
            (partkey: a, sourceNote: "Raw/a.md"), (partkey: b, sourceNote: "Raw/b2.md"),
            (partkey: c, sourceNote: "Raw/c.md"),
        ])
        #expect(added == 1)
        #expect(try f.store.importedKeys() == [b, c])
        #expect(try f.string("SELECT source_note FROM imported_keys WHERE partkey = ?", [b]) == "Raw/b.md")
        #expect(try f.string("SELECT imported_at FROM imported_keys WHERE partkey = ?", [c]) == StoreFixture.nowISO)
    }

    @Test("集計列を数え直す")
    func refreshAggregates() throws {
        let f = try StoreFixture(stepping: true)
        let session = "DJIMIC3:20260829"
        try f.store.insertSession(Builders.session())
        let p1 = try f.makeRecording(
            Builders.recording(
                relpath: StoreFixture.relpath("p1"), startedAt: "2026-08-29T07:00:00+09:00", durationSeconds: 100))
        let p2 = try f.makeRecording(
            Builders.recording(
                relpath: StoreFixture.relpath("p2"), startedAt: "2026-08-29T07:10:00+09:00", durationSeconds: nil),
            path: [.skipped])
        let p3 = try f.makeRecording(
            Builders.recording(
                relpath: StoreFixture.relpath("p3"), startedAt: "2026-08-29T07:20:00+09:00", durationSeconds: 50))
        for key in [p1, p2, p3] {
            try f.store.updateRecording(key, [.sessionKey(session)])
        }
        let before = try #require(try f.store.session(session)?.updatedAt)
        try f.store.refreshSessionAggregates(session)
        let row = try #require(try f.store.session(session))
        #expect(row.partCount == 3)
        #expect(row.startedAt == "2026-08-29T07:00:00+09:00")
        #expect(row.endedAt == "2026-08-29T07:20:50+09:00")
        #expect(row.recordedSeconds == 150)
        #expect(row.failedPartCount == 1)
        #expect(row.updatedAt > before)
        #expect(row.status == .open)
    }

    @Test("duration が全部 NULL なら recorded_seconds は NULL")
    func refreshAggregatesAllNullDuration() throws {
        let f = try StoreFixture()
        let session = "DJIMIC3:20260829"
        try f.store.insertSession(Builders.session())
        for name in ["a", "b"] {
            let key = try f.makeRecording(
                Builders.recording(relpath: StoreFixture.relpath(name), durationSeconds: nil))
            try f.store.updateRecording(key, [.sessionKey(session)])
        }
        try f.store.refreshSessionAggregates(session)
        let row = try #require(try f.store.session(session))
        #expect(row.partCount == 2)
        #expect(row.recordedSeconds == nil)
        #expect(row.endedAt == nil)
    }

    @Test("Part が 0 件なら 0・NULL")
    func refreshAggregatesNoParts() throws {
        let f = try StoreFixture()
        let session = "DJIMIC3:20260829"
        try f.store.insertSession(Builders.session())
        try f.store.updateSession(session, [.partCount(5), .failedPartCount(2), .recordedSeconds(9)])
        try f.store.refreshSessionAggregates(session)
        let row = try #require(try f.store.session(session))
        #expect(row.partCount == 0)
        #expect(row.recordedSeconds == nil)
        #expect(row.failedPartCount == 0)
        #expect(row.startedAt == nil)
    }
}
