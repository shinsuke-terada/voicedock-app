// Part の 16 kHz 変換の呼び手の手順のテスト（T-18 §6.7。PLAN §8.3）。本物の AVFoundation と BWF。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDStore

@testable import VDPipeline

@Suite("PartStepsNormalize", .serialized)
struct PartStepsNormalizeTests {
    /// target までの通常の遷移の列（DISCOVERED から）。
    static func path(to target: PartStatus) -> [PartStatus] {
        let full: [PartStatus] = [.normalizing, .normalized, .transcribing, .transcribed, .rawWriting, .rawSaved]
        switch target {
        case .completed: return full + [.completed]
        case .failed: return [.normalizing, .failed]
        case .skipped: return [.skipped]
        default:
            guard let index = full.firstIndex(of: target) else { return [] }
            return Array(full[...index])
        }
    }

    static func normalize(_ w: PipelineWorld, _ pk: String, ctx: TickContext? = nil) async throws -> Bool {
        let context: TickContext
        if let ctx {
            context = ctx
        } else {
            context = try await w.context()
        }
        return await PartSteps(ctx: context).ensureNormalized(try w.part(pk))
    }

    static func inbox(_ w: PipelineWorld, _ relpath: String = PipelineFixtures.relpath) -> URL {
        w.layout.inboxFile(deviceID: "DJIMIC3", relpath: relpath)
    }

    @Test("変換して DB を書き、その後で inbox を消す")
    func normalizesAndReleasesInbox() async throws {
        let w = try await PipelineWorld.make()
        let pk = try w.registerPart()
        let inbox = Self.inbox(w)
        let sha = try FileHasher.sha256(of: inbox, chunkBytes: 1_048_576)
        let inBytes = try PipelineFixtures.size(of: inbox)

        #expect(try await Self.normalize(w, pk))

        let slug = KeySlug.of(pk)
        let row = try w.part(pk)
        #expect(row.status == .normalized)
        #expect(row.sha256 == sha)
        #expect(row.normalizedPath == "staging/" + slug + "/audio16k.wav")
        #expect(row.stagingDir == "staging/" + slug)
        #expect(!PipelineFixtures.exists(inbox))
        let outBytes = try PipelineFixtures.size(of: w.layout.normalizedAudio(slug: slug))
        let expected =
            "INFO  normalize_completed recording_key=\(PipelineFixtures.partkey) in_bytes=\(inBytes) out_bytes=\(outBytes) elapsed_s=0.0"
        #expect(w.lines("normalize_completed").contains { $0.hasSuffix(expected) })
    }

    @Test("CE audio.inboxRetain raw_saved なら NORMALIZED で inbox を消さない")
    func ceAudioInboxRetainRawSaved() async throws {
        let w = try await PipelineWorld.make { $0.audio.inboxRetain = "raw_saved" }
        let pk = try w.registerPart()
        #expect(try await Self.normalize(w, pk))
        #expect(try w.part(pk).status == .normalized)
        #expect(PipelineFixtures.exists(Self.inbox(w)))
    }

    @Test("inbox が無ければ SKIPPED(SOURCE_MISSING)")
    func missingInboxIsSourceMissing() async throws {
        let w = try await PipelineWorld.make()
        let pk = try w.registerPart()
        try FileManager.default.removeItem(at: Self.inbox(w))
        #expect(try await Self.normalize(w, pk) == false)
        let row = try w.part(pk)
        #expect(row.status == .skipped)
        #expect(row.errorCode == .sourceMissing)
        #expect(row.errorMessage == "inbox に原本がありません: inbox/DJIMIC3/" + PipelineFixtures.relpath)
        #expect(w.lines("part_skipped").contains { $0.hasSuffix("reason=source_missing") })
    }

    @Test("0 バイトは無いのと同じ")
    func emptyInboxIsMissing() async throws {
        let w = try await PipelineWorld.make()
        let pk = try w.registerPart()
        try Data().write(to: Self.inbox(w))
        _ = try await Self.normalize(w, pk)
        #expect(try w.part(pk).status == .skipped)
    }

    @Test("needs_recopy なら SKIPPED にせず待つ")
    func needsRecopyWaits() async throws {
        let w = try await PipelineWorld.make()
        let pk = try w.registerPart()
        try FileManager.default.removeItem(at: Self.inbox(w))
        try w.store.updateRecording(pk, [.needsRecopy(true)])
        let before = try w.partEvents(pk).count
        #expect(try await Self.normalize(w, pk) == false)
        #expect(try w.part(pk).status == .discovered)
        #expect(try w.partEvents(pk).count == before)
    }

    @Test("空き容量が足りなければ遷移しない")
    func diskSpaceGuardDoesNotTransition() async throws {
        let w = try await PipelineWorld.make {
            $0.audio.freeSpaceMarginBytes = Int.max / 4
            $0.audio.stagingMaxBytes = Int.max / 2
        }
        let pk = try w.registerPart()
        let ctx = try await w.context()
        #expect(try await Self.normalize(w, pk, ctx: ctx) == false)
        #expect(try w.part(pk).status == .discovered)
        #expect(
            w.lines("disk_space_low").filter { $0.contains("recording_key=" + PipelineFixtures.partkey) }.count == 1)
        #expect(ctx.pauses.paused.contains(.diskSpaceLow))
    }

    @Test("NORMALIZING から入っても遷移を記録しない")
    func normalizingEntryRecordsNoPhantom() async throws {
        let w = try await PipelineWorld.make()
        let pk = try w.registerPart()
        try w.movePart(pk, [.normalizing])
        #expect(try await Self.normalize(w, pk))
        #expect(try w.part(pk).status == .normalized)
        let entries = try w.partEvents(pk).filter { $0.fromStatus == "DISCOVERED" && $0.toStatus == "NORMALIZING" }
        #expect(entries.count == 1)
    }

    @Test("同じ内容は duplicate_of を先に書いて SKIPPED")
    func duplicateIsSkippedWithDuplicateOf() async throws {
        let w = try await PipelineWorld.make()
        let first = try w.registerPart()
        let second = try w.registerPart(
            relpath: "TX_MIC001_20260829_071201/TX01_MIC002_20260829_081204_orig.wav",
            startedAt: "2026-08-29T08:12:04+09:00")
        #expect(try await Self.normalize(w, first))
        #expect(try await Self.normalize(w, second) == false)
        let row = try w.part(second)
        #expect(row.status == .skipped)
        #expect(row.errorCode == .duplicateContent)
        #expect(row.duplicateOf == first)
        #expect(row.sha256 == nil)
        #expect(row.errorMessage == "同じ内容の Part が既にあります: " + PipelineFixtures.partkey)
    }

    @Test("SOURCE_HASH_MISMATCH は needs_recopy = 1")
    func hashMismatchSetsNeedsRecopy() async throws {
        let w = try await PipelineWorld.make()
        let pk = try w.registerPart()
        try w.store.updateRecording(pk, [.sha256Helper(String(repeating: "b", count: 64))])
        #expect(try await Self.normalize(w, pk) == false)
        let row = try w.part(pk)
        #expect(row.status == .failed)
        #expect(row.errorCode == .sourceHashMismatch)
        #expect(row.needsRecopy)
        let expected =
            "ERROR normalize_failed recording_key=\(PipelineFixtures.partkey) error_code=SOURCE_HASH_MISMATCH"
        #expect(w.lines("normalize_failed").contains { $0.hasSuffix(expected) })
    }

    @Test("NORMALIZED 以降は真を返すだけ", arguments: [PartStatus.normalized, .transcribed, .completed])
    func alreadyNormalizedIsTrue(_ status: PartStatus) async throws {
        let w = try await PipelineWorld.make()
        let pk = try w.insertPart()
        try w.movePart(pk, Self.path(to: status))
        let before = try w.partEvents(pk).count
        #expect(try await Self.normalize(w, pk))
        #expect(try w.partEvents(pk).count == before)
    }

    @Test("FAILED / SKIPPED は進めない", arguments: [PartStatus.failed, .skipped])
    func failedAndSkippedAreFalse(_ status: PartStatus) async throws {
        let w = try await PipelineWorld.make()
        let pk = try w.registerPart()
        try w.movePart(pk, Self.path(to: status))
        #expect(try await Self.normalize(w, pk) == false)
        #expect(try w.part(pk).status == status)
    }
}
