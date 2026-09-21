// 状態遷移と行の作成（PLAN §5.2・付録 A.1〜A.2）。期待値は仕様の表の固定値。
import Foundation
import GRDB
import TestSupport
import Testing
import VDCore

@testable import VDStore

@Suite("状態遷移")
struct TransitionsTests {
    func event(_ f: StoreFixture, _ entity: EntityType, _ key: String, at index: Int) throws -> EventRow {
        let events = try f.store.events(entity: entity, key: key)
        return try #require(events.count > index ? events[index] : nil)
    }

    @Test("行の作成も events に書く")
    func insertRecordingWritesBirthEvent() throws {
        let f = try StoreFixture()
        let key = try f.makeRecording(Builders.recording())
        let row = try #require(try f.store.recording(key))
        #expect(row.status == .discovered)
        #expect(row.retryCount == 0)
        #expect(row.updatedAt == StoreFixture.nowISO)
        #expect(try f.eventCount() == 1)
        let e = try event(f, .recording, key, at: 0)
        #expect(e.entityType == .recording)
        #expect(try f.string("SELECT entity_type FROM events WHERE id = ?", [e.id]) == "recording")
        #expect(e.fromStatus == nil)
        #expect(e.toStatus == "DISCOVERED")
        #expect(e.errorCode == nil)
        #expect(e.detail == nil)
        #expect(e.createdAt == StoreFixture.nowISO)
    }

    @Test("Session の作成も events に書く")
    func insertSessionWritesBirthEvent() throws {
        let f = try StoreFixture()
        try f.store.insertSession(Builders.session())
        let row = try #require(try f.store.session("DJIMIC3:20260829"))
        #expect(row.status == .open)
        let events = try f.store.events(entity: .session, key: "DJIMIC3:20260829")
        #expect(events.count == 1)
        #expect(events.first?.fromStatus == nil)
        #expect(events.first?.toStatus == "OPEN")
    }

    @Test("同じ partkey の 2 回目は失敗し events を増やさない")
    func insertDuplicatePartkeyFails() throws {
        let f = try StoreFixture()
        try f.store.insertRecording(Builders.recording())
        #expect(throws: DatabaseError.self) {
            try f.store.insertRecording(Builders.recording())
        }
        #expect(try f.eventCount() == 1)
    }

    @Test("遷移は行と events を同じトランザクションで書く")
    func recordsTransitionAndEvent() throws {
        let f = try StoreFixture()
        let key = try f.makeRecording(Builders.recording())
        try f.store.recordPartTransition(partkey: key, from: .discovered, to: .normalizing, detail: "x")
        #expect(try f.store.recording(key)?.status == .normalizing)
        let e = try event(f, .recording, key, at: 1)
        #expect(e.fromStatus == "DISCOVERED")
        #expect(e.toStatus == "NORMALIZING")
        #expect(e.detail == "x")
    }

    @Test("現在の状態が from と違えば TransitionConflict で何も変えない")
    func conflictWhenFromDoesNotMatch() throws {
        let f = try StoreFixture()
        let key = try f.makeRecording(Builders.recording())
        let before = try f.store.recording(key)
        #expect(throws: TransitionConflict(key: key, expected: "NORMALIZED")) {
            try f.store.recordPartTransition(partkey: key, from: .normalized, to: .transcribing)
        }
        #expect(try f.store.recording(key) == before)
        #expect(try f.eventCount() == 1)
    }

    @Test("行が無ければ TransitionConflict")
    func conflictWhenRowMissing() throws {
        let f = try StoreFixture()
        #expect(throws: TransitionConflict(key: "DJIMIC3/none.wav", expected: "DISCOVERED")) {
            try f.store.recordPartTransition(partkey: "DJIMIC3/none.wav", from: .discovered, to: .normalizing)
        }
        #expect(try f.eventCount() == 0)
    }

    @Test("遷移表に無い辺は IllegalTransition で DB に触らない")
    func illegalNormalEdgeIsRejected() throws {
        let f = try StoreFixture()
        let key = try f.makeRecording(Builders.recording())
        #expect(throws: IllegalTransition(from: "DISCOVERED", to: "COMPLETED", kind: .normal)) {
            try f.store.recordPartTransition(partkey: key, from: .discovered, to: .completed)
        }
        #expect(try f.store.recording(key)?.status == .discovered)
        #expect(try f.eventCount() == 1)
    }

    @Test("復旧の辺は recovery でだけ通る")
    func recoveryEdgeNeedsRecoveryKind() throws {
        let f = try StoreFixture()
        let key = try f.makeRecording(Builders.recording(), path: [.normalizing])
        #expect(throws: IllegalTransition(from: "NORMALIZING", to: "DISCOVERED", kind: .normal)) {
            try f.store.recordPartTransition(partkey: key, from: .normalizing, to: .discovered, kind: .normal)
        }
        #expect(try f.store.recording(key)?.status == .normalizing)
    }

    @Test("recovery の detail は引数によらず recovery")
    func recoveryEdgeWritesRecoveryDetail() throws {
        let f = try StoreFixture()
        let key = try f.makeRecording(Builders.recording(), path: [.normalizing])
        try f.store.recordPartTransition(
            partkey: key, from: .normalizing, to: .discovered, kind: .recovery, detail: "ignored")
        #expect(try f.store.recording(key)?.status == .discovered)
        #expect(try event(f, .recording, key, at: 2).detail == "recovery")
    }

    @Test("recovery は写像の組だけを許す")
    func recoveryKindRejectsNonRecoveryEdge() throws {
        let f = try StoreFixture()
        let key = try f.makeRecording(Builders.recording())
        #expect(throws: IllegalTransition(from: "DISCOVERED", to: "NORMALIZING", kind: .recovery)) {
            try f.store.recordPartTransition(partkey: key, from: .discovered, to: .normalizing, kind: .recovery)
        }
        #expect(try f.eventCount() == 1)
    }

    @Test("SOURCE_DELETING→SOURCE_DELETE_PENDING は両方で通る")
    func sharedEdgeAllowedByBothKinds() throws {
        let f = try StoreFixture()
        let path = StoreFixture.path(to: .sourceDeleting)
        let a = try f.makeRecording(Builders.recording(relpath: StoreFixture.relpath("a")), path: path)
        let b = try f.makeRecording(Builders.recording(relpath: StoreFixture.relpath("b")), path: path)
        try f.store.recordPartTransition(partkey: a, from: .sourceDeleting, to: .sourceDeletePending, kind: .normal)
        try f.store.recordPartTransition(partkey: b, from: .sourceDeleting, to: .sourceDeletePending, kind: .recovery)
        #expect(try f.store.recording(a)?.status == .sourceDeletePending)
        #expect(try f.store.recording(b)?.status == .sourceDeletePending)
    }

    @Test("Session も遷移表で検査する")
    func sessionIllegalEdgeIsRejected() throws {
        let f = try StoreFixture()
        try f.store.insertSession(Builders.session())
        #expect(throws: IllegalTransition(from: "OPEN", to: "ANALYZED", kind: .normal)) {
            try f.store.recordSessionTransition(sessionKey: "DJIMIC3:20260829", from: .open, to: .analyzed)
        }
        #expect(try f.store.session("DJIMIC3:20260829")?.status == .open)
    }

    @Test("OPEN→OPEN は遷移として events に書く")
    func openToOpenIsATransition() throws {
        let f = try StoreFixture()
        let key = "DJIMIC3:20260829"
        let partkey = "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
        try f.store.insertSession(Builders.session())
        try f.store.recordSessionTransition(sessionKey: key, from: .open, to: .open, detail: partkey)
        let e = try event(f, .session, key, at: 1)
        #expect(e.fromStatus == "OPEN")
        #expect(e.toStatus == "OPEN")
        #expect(e.detail == partkey)
    }

    /// retry_count の規則の 1 行。path を辿ると initial になり、最後の辺で expected になる
    struct RetryCase: Sendable, CustomTestStringConvertible {
        let initial: Int
        let part: [PartStatus]
        let session: [SessionStatus]
        let resetRetry: Bool
        let expected: Int

        var testDescription: String {
            let names = part.isEmpty ? session.suffix(2).map(\.rawValue) : part.suffix(2).map(\.rawValue)
            return "\(initial) \(names.joined(separator: " → ")) reset=\(resetRetry) → \(expected)"
        }

        static func part(_ initial: Int, _ path: [PartStatus], reset: Bool = false, _ expected: Int) -> RetryCase {
            RetryCase(initial: initial, part: path, session: [], resetRetry: reset, expected: expected)
        }

        static func session(_ initial: Int, _ path: [SessionStatus], _ expected: Int) -> RetryCase {
            RetryCase(initial: initial, part: [], session: path, resetRetry: false, expected: expected)
        }
    }

    static let retryCases: [RetryCase] = [
        // 2 | NORMALIZING → NORMALIZED | false | 0
        .part(2, [.normalizing, .failed, .normalizing, .failed, .normalizing, .normalized], 0),
        // 2 | TRANSCRIBING → TRANSCRIBED | false | 0
        .part(
            2,
            [.normalizing, .normalized, .transcribing, .failed, .transcribing, .failed, .transcribing, .transcribed],
            0),
        // 2 | RAW_WRITING → RAW_SAVED | false | 0
        .part(
            2,
            [
                .normalizing, .normalized, .transcribing, .transcribed, .rawWriting, .failed, .rawWriting, .failed,
                .rawWriting, .rawSaved,
            ], 0),
        // 1 | NORMALIZING → FAILED | false | 2
        .part(1, [.normalizing, .failed, .normalizing, .failed], 2),
        // 2 | FAILED → NORMALIZING | false | 2
        .part(2, [.normalizing, .failed, .normalizing, .failed, .normalizing], 2),
        // 3 | FAILED → NORMALIZING | true | 0
        .part(3, [.normalizing, .failed, .normalizing, .failed, .normalizing, .failed, .normalizing], reset: true, 0),
        // 1 | DISCOVERED → NORMALIZING | false | 1（NORMALIZING → DISCOVERED は復旧写像）
        .part(1, [.normalizing, .failed, .normalizing, .discovered, .normalizing], 1),
        // 2 | MERGING → MERGED（Session） | false | 0
        .session(2, [.ready, .merging, .failed, .merging, .failed, .merging, .merged], 0),
        // 2 | ANALYZING → ANALYZED（Session） | false | 0
        .session(
            2, [.ready, .merging, .merged, .analyzing, .failed, .analyzing, .failed, .analyzing, .analyzed], 0),
        // 2 | WRITING → SAVED（Session） | false | 0
        .session(
            2,
            [
                .ready, .merging, .merged, .analyzing, .analyzed, .writing, .failed, .writing, .failed, .writing,
                .saved,
            ], 0),
        // 0 | ANALYZING → FAILED（Session） | false | 1
        .session(0, [.ready, .merging, .merged, .analyzing, .failed], 1),
    ]

    @Test("retry_count の規則（SM-03 / SM-04）", arguments: retryCases)
    func retryCountRules(_ c: RetryCase) throws {
        let f = try StoreFixture()
        if c.part.isEmpty {
            let key = "DJIMIC3:20260829"
            try f.store.insertSession(Builders.session())
            let setup = Array(c.session.dropLast())
            try f.walkSession(key, from: .open, through: setup)
            #expect(try f.store.session(key)?.retryCount == c.initial)
            let from = setup.last ?? .open
            guard let to = c.session.last else { return }
            try f.store.recordSessionTransition(sessionKey: key, from: from, to: to, resetRetry: c.resetRetry)
            #expect(try f.store.session(key)?.retryCount == c.expected)
        } else {
            let key = try f.makeRecording(Builders.recording(), path: Array(c.part.dropLast()))
            #expect(try f.store.recording(key)?.retryCount == c.initial)
            let from = c.part.dropLast().last ?? .discovered
            guard let to = c.part.last else { return }
            try f.store.recordPartTransition(partkey: key, from: from, to: to, resetRetry: c.resetRetry)
            #expect(try f.store.recording(key)?.retryCount == c.expected)
        }
    }

    @Test("error_code と error_message は無条件に上書き")
    func errorFieldsAreOverwrittenUnconditionally() throws {
        let f = try StoreFixture()
        let key = try f.makeRecording(Builders.recording(), path: [.normalizing, .normalized, .transcribing])
        try f.store.recordPartTransition(
            partkey: key, from: .transcribing, to: .failed, errorCode: .whisperFailed, errorMessage: "m")
        #expect(try f.string("SELECT error_code FROM recordings WHERE partkey = ?", [key]) == "WHISPER_FAILED")
        #expect(try f.string("SELECT error_message FROM recordings WHERE partkey = ?", [key]) == "m")
        try f.store.recordPartTransition(partkey: key, from: .failed, to: .transcribing)
        #expect(try f.value("SELECT error_code FROM recordings WHERE partkey = ?", [key]) == .null)
        #expect(try f.value("SELECT error_message FROM recordings WHERE partkey = ?", [key]) == .null)
    }

    struct TruncationCase: Sendable, CustomTestStringConvertible {
        let label: String
        let input: String
        let expected: String
        var testDescription: String { label }
    }

    static let truncationCases: [TruncationCase] = [
        TruncationCase(
            label: "a × 200 はそのまま", input: String(repeating: "a", count: 200),
            expected: String(repeating: "a", count: 200)),
        TruncationCase(
            label: "a × 201 は a × 199 + …", input: String(repeating: "a", count: 201),
            expected: String(repeating: "a", count: 199) + "\u{2026}"),
        TruncationCase(
            label: "e + U+0301 × 101（202 スカラー）は先頭 199 スカラー + …",
            input: String(repeating: "e\u{301}", count: 101),
            expected: String(repeating: "e\u{301}", count: 99) + "e" + "\u{2026}"),
        TruncationCase(label: "空文字は空文字", input: "", expected: ""),
    ]

    @Test("200 スカラーで切り詰める（書記素ではない）", arguments: truncationCases)
    func errorMessageTruncatedByScalars(_ c: TruncationCase) throws {
        let f = try StoreFixture()
        let key = try f.makeRecording(Builders.recording())
        try f.store.recordPartTransition(
            partkey: key, from: .discovered, to: .normalizing, errorMessage: c.input, detail: c.input)
        let stored = try #require(try f.string("SELECT error_message FROM recordings WHERE partkey = ?", [key]))
        let detail = try #require(try event(f, .recording, key, at: 1).detail)
        #expect(Array(stored.unicodeScalars) == Array(c.expected.unicodeScalars))
        #expect(Array(detail.unicodeScalars) == Array(c.expected.unicodeScalars))
        #expect(stored.unicodeScalars.count == c.expected.unicodeScalars.count)
    }

    @Test("時刻は呼ぶたびに時計から取る")
    func timestampsComeFromClockEachCall() throws {
        let f = try StoreFixture(stepping: true)
        // insertRecording が 07:00:12、1 回目の遷移が 07:00:13、2 回目が 07:00:14
        let key = try f.makeRecording(Builders.recording())
        try f.store.recordPartTransition(partkey: key, from: .discovered, to: .normalizing)
        let first = try f.store.recording(key)?.updatedAt
        try f.store.recordPartTransition(partkey: key, from: .normalizing, to: .normalized)
        let second = try f.store.recording(key)?.updatedAt
        #expect(first == "2026-08-30T07:00:13+09:00")
        #expect(second == "2026-08-30T07:00:14+09:00")
    }

    @Test("status が一致するときだけ列を更新する")
    func updateRecordingIfStatusOnlyWhenMatching() throws {
        let f = try StoreFixture()
        let key = try f.makeRecording(Builders.recording())
        #expect(try f.store.updateRecordingIfStatus(key, status: .normalized, [.needsRecopy(true)]) == false)
        #expect(try f.int("SELECT needs_recopy FROM recordings WHERE partkey = ?", [key]) == 0)
        #expect(try f.store.updateRecordingIfStatus(key, status: .discovered, [.needsRecopy(true)]) == true)
        #expect(try f.int("SELECT needs_recopy FROM recordings WHERE partkey = ?", [key]) == 1)
        #expect(try f.store.recording(key)?.status == .discovered)
    }
}
