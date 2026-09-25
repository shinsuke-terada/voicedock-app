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
    /// RIFF のサイズの欄の位置
    static let riffSizeOffset = 4

    /// 4 秒の録音で、data のサイズの欄は 2 秒（288000 バイト）のまま。`riffSize` を渡せば RIFF のサイズの欄も古くする。
    /// 登録時の duration 2.0 もこのヘッダから測った値と同じ。inbox に書き、sha256Helper をこの内容の SHA-256 にする。
    static func writeStaleInbox(_ w: PipelineWorld, _ pk: String, riffSize: UInt32? = nil) throws -> (URL, Data) {
        let inbox = w.layout.inboxFile(deviceID: "DJIMIC3", relpath: PipelineFixtures.relpath)
        var blob = try BWFWriter.build(seconds: 4, format: .pcm24, content: .speech)
        blob.replaceSubrange(dataSizeOffset..<(dataSizeOffset + 4), with: le32(288_000))
        if let riffSize {
            blob.replaceSubrange(riffSizeOffset..<(riffSizeOffset + 4), with: le32(riffSize))
        }
        try blob.write(to: inbox)
        try w.store.updateRecording(pk, [.sha256Helper(try FileHasher.sha256(of: inbox, chunkBytes: 1_048_576))])
        return (inbox, blob)
    }

    static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    @Test("F-77 ヘッダが実データより短い inbox の原本は FAILED(NORMALIZE_VERIFY_FAILED)。inboxRetain=normalized でも inbox を消さない")
    func staleHeaderKeepsInbox() async throws {
        let w = try await PipelineWorld.make { $0.audio.inboxRetain = "normalized" }
        let pk = try w.registerPart(seconds: 2.0)
        let (inbox, blob) = try Self.writeStaleInbox(w, pk)

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

    @Test("F-77 RIFF のサイズの欄も古い inbox の原本も FAILED（開ければ NORMALIZE_VERIFY_FAILED、開けなければ IMPORT_FAILED）で、inbox を消さない")
    func staleRIFFAndDataSizeKeepsInbox() async throws {
        let w = try await PipelineWorld.make { $0.audio.inboxRetain = "normalized" }
        let pk = try w.registerPart(seconds: 2.0)
        // RIFF のサイズ = 2 秒のファイルの全長 − 8 = 32776 + 288000 − 8
        let (inbox, blob) = try Self.writeStaleInbox(w, pk, riffSize: 320_768)

        #expect(try await PartStepsNormalizeTests.normalize(w, pk) == false)

        let row = try w.part(pk)
        #expect(row.status == .failed)
        let code = try #require(row.errorCode)
        #expect([ErrorCode.normalizeVerifyFailed, .importFailed].contains(code))
        #expect(row.sha256 == nil)
        #expect(try Data(contentsOf: inbox) == blob)
        #expect(!PipelineFixtures.exists(w.layout.normalizedAudio(slug: KeySlug.of(pk))))
    }
}
