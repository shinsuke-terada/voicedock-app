// ヘッダが実データより短い inbox の原本を NORMALIZED にせず、inbox も消さない（PLAN §8.3 手順 6・呼び手の手順 6〜7。F-77・issue #117）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDStore

@testable import VDPipeline

@Suite("PartStepsNormalize（F-77 入力のヘッダ）", .serialized)
struct PartStepsNormalizeExtentTests {
    /// BWF の data のサイズの欄の位置（data は 32776 から。その直前の 4 バイト）
    static let dataSizeOffset = BWFWriter.bwfHeaderBytes - 4

    @Test("F-77 ヘッダが実データより短い inbox の原本は FAILED(NORMALIZE_VERIFY_FAILED)。inboxRetain=normalized でも inbox を消さない")
    func staleHeaderKeepsInbox() async throws {
        let w = try await PipelineWorld.make { $0.audio.inboxRetain = "normalized" }
        let pk = try w.registerPart(seconds: 2.0)
        let inbox = w.layout.inboxFile(deviceID: "DJIMIC3", relpath: PipelineFixtures.relpath)
        // 4 秒の録音で、ヘッダは 2 秒のまま（登録時の duration 2.0 もこのヘッダから測った値と同じ）
        var blob = try BWFWriter.build(seconds: 4, format: .pcm24, content: .speech)
        let declared = UInt32(288_000).littleEndian
        blob.replaceSubrange(
            Self.dataSizeOffset..<(Self.dataSizeOffset + 4), with: withUnsafeBytes(of: declared) { Data($0) })
        try blob.write(to: inbox)
        try w.store.updateRecording(pk, [.sha256Helper(try FileHasher.sha256(of: inbox, chunkBytes: 1_048_576))])

        #expect(try await PartStepsNormalizeTests.normalize(w, pk) == false)

        let row = try w.part(pk)
        #expect(row.status == .failed)
        #expect(row.errorCode == .normalizeVerifyFailed)
        #expect(row.errorMessage == "入力のヘッダの長さと実データの量が合いません（ヘッダ 96000 フレーム、実データ 192000 フレーム）")
        #expect(row.sha256 == nil)
        #expect(try Data(contentsOf: inbox) == blob)
        #expect(!PipelineFixtures.exists(w.layout.normalizedAudio(slug: KeySlug.of(pk))))
        let expected =
            "ERROR normalize_failed recording_key=\(PipelineFixtures.partkey) error_code=NORMALIZE_VERIFY_FAILED"
        #expect(w.lines("normalize_failed").contains { $0.hasSuffix(expected) })
    }
}
