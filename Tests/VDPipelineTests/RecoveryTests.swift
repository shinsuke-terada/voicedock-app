// 起動時の復旧のテスト（T-18 §6.2。PLAN §5.3）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDStore

@testable import VDPipeline

@Suite("Recovery")
struct RecoveryTests {
    static func recovery(_ w: PipelineWorld) async throws -> Recovery {
        guard let config = await w.configStore.current() else { throw PipelineFixtureError.noConfig }
        return Recovery(store: w.store, layout: w.layout, log: w.log, config: config, zone: PipelineFixtures.zone)
    }

    static func relpath(_ hhmmss: String) -> String {
        "TX_MIC001_20260829_071201/TX01_MIC002_20260829_" + hhmmss + "_orig.wav"
    }

    static func put(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: url)
    }

    @Test("進行中の状態を全部 1 つ戻す")
    func rollsBackEveryInProgressState() async throws {
        let w = try await PipelineWorld.make()
        let toNormalized: [PartStatus] = [.normalizing, .normalized]
        let toTranscribed = toNormalized + [.transcribing, .transcribed]
        let toRawSaved = toTranscribed + [.rawWriting, .rawSaved]
        let parts = [
            (try w.insertPart(relpath: Self.relpath("071201")), [PartStatus.normalizing]),
            (try w.insertPart(relpath: Self.relpath("071202")), toNormalized + [.transcribing]),
            (try w.insertPart(relpath: Self.relpath("071203")), toTranscribed + [.rawWriting]),
            (try w.insertPart(relpath: Self.relpath("071204")), toRawSaved + [.sourceDeleting]),
        ]
        for (pk, path) in parts { try w.movePart(pk, path) }
        let toMerged: [SessionStatus] = [.ready, .merging, .merged]
        let toAnalyzed = toMerged + [.analyzing, .analyzed]
        let toSaved = toAnalyzed + [.writing, .saved]
        let sessions: [(String, [SessionStatus])] = [
            ("DJIMIC3:20260801", [.ready, .merging]),
            ("DJIMIC3:20260802", toMerged + [.analyzing]),
            ("DJIMIC3:20260803", toAnalyzed + [.writing]),
            ("DJIMIC3:20260804", toSaved + [.sourceDeleting]),
            ("DJIMIC3:20260805", toSaved + [.cleanup]),
        ]
        for (key, path) in sessions { try w.moveSession(key, path) }

        let moved = try await Self.recovery(w).run()

        #expect(moved == 9)
        let partStatuses = try parts.map { try w.part($0.0).status }
        #expect(partStatuses == [.discovered, .normalized, .transcribed, .sourceDeletePending])
        let sessionStatuses = try sessions.map { try w.store.session($0.0)?.status }
        #expect(sessionStatuses == [.ready, .merged, .analyzed, .sourceDeletePending, .saved])
        for (pk, _) in parts { #expect(try w.partEvents(pk).last?.detail == "recovery") }
        for (key, _) in sessions {
            #expect(try w.store.events(entity: .session, key: key).last?.detail == "recovery")
        }
        #expect(w.lines("recovery_completed").contains { $0.hasSuffix("INFO  recovery_completed rolled_back=9") })
    }

    @Test("戻す順は写像の順・started_at 順")
    func orderIsPlanOrder() async throws {
        let w = try await PipelineWorld.make()
        let transcribing = try w.insertPart(relpath: Self.relpath("070000"), startedAt: "2026-08-29T07:00:00+09:00")
        let normalizing = try w.insertPart(relpath: Self.relpath("080000"), startedAt: "2026-08-29T08:00:00+09:00")
        try w.movePart(transcribing, [.normalizing, .normalized, .transcribing])
        try w.movePart(normalizing, [.normalizing])
        _ = try await Self.recovery(w).run()
        let n = try #require(try w.partEvents(normalizing).last)
        let t = try #require(try w.partEvents(transcribing).last)
        #expect(n.detail == "recovery" && t.detail == "recovery")
        #expect(n.id < t.id)
    }

    @Test("NORMALIZING の部分出力は partkey から消す（列が NULL でも）")
    func normalizingPartialIsComputedFromPartkey() async throws {
        let w = try await PipelineWorld.make()
        let pk = try w.insertPart()
        try w.movePart(pk, [.normalizing])
        #expect(try w.part(pk).normalizedPath == nil)
        let slug = KeySlug.of(pk)
        try Self.put(w.layout.normalizedAudio(slug: slug))
        try Self.put(w.layout.normalizedAudioTmp(slug: slug))
        _ = try await Self.recovery(w).run()
        #expect(!PipelineFixtures.exists(w.layout.normalizedAudio(slug: slug)))
        #expect(!PipelineFixtures.exists(w.layout.normalizedAudioTmp(slug: slug)))
    }

    @Test("TRANSCRIBING の部分出力を消す")
    func transcribingPartialIsRemoved() async throws {
        let w = try await PipelineWorld.make()
        let pk = try w.insertPart()
        try w.movePart(pk, [.normalizing, .normalized, .transcribing])
        let slug = KeySlug.of(pk)
        try Self.put(w.layout.transcript(slug: slug))
        try Self.put(w.layout.whisperJSON(slug: slug))
        try Self.put(w.layout.diarizationRTTM(slug: slug))
        _ = try await Self.recovery(w).run()
        #expect(!PipelineFixtures.exists(w.layout.transcript(slug: slug)))
        #expect(!PipelineFixtures.exists(w.layout.whisperJSON(slug: slug)))
        #expect(!PipelineFixtures.exists(w.layout.diarizationRTTM(slug: slug)))
    }

    @Test("SOURCE_DELETING→PENDING で delete_request_id を外さない")
    func deleteRequestIDIsKept() async throws {
        let w = try await PipelineWorld.make()
        let pk = try w.insertPart()
        try w.movePart(
            pk, [.normalizing, .normalized, .transcribing, .transcribed, .rawWriting, .rawSaved, .sourceDeleting])
        try w.store.updateRecording(pk, [.deleteRequestID("x")])
        _ = try await Self.recovery(w).run()
        let row = try w.part(pk)
        #expect(row.status == .sourceDeletePending)
        #expect(row.deleteRequestID == "x")
    }

    @Test("消せなくても続ける")
    func unlinkFailureWarnsAndContinues() async throws {
        let w = try await PipelineWorld.make()
        let pk = try w.insertPart()
        try w.movePart(pk, [.normalizing])
        try FileManager.default.createDirectory(
            at: w.layout.normalizedAudio(slug: KeySlug.of(pk)), withIntermediateDirectories: true)
        _ = try await Self.recovery(w).run()
        #expect(try w.part(pk).status == .discovered)
        #expect(w.lines("config_warning").contains { $0.contains("WARNING config_warning rule=recovery") })
    }

    @Test("戻すものが無ければ何も出さない")
    func nothingToRecoverLogsNothing() async throws {
        let w = try await PipelineWorld.make()
        let moved = try await Self.recovery(w).run()
        #expect(moved == 0)
        #expect(w.sink.lines == [])
    }
}
