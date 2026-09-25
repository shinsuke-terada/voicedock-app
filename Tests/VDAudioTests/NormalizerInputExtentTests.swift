// 変換の手順 2・6 での入力のヘッダの照合（PLAN §8.3。F-77・issue #117）。入力は一時ディレクトリの inbox に手で組んだ WAV。
import CryptoKit
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore

@testable import VDAudio

@Suite("Normalizer（F-77 入力のヘッダ）", .serialized)
struct NormalizerInputExtentTests {
    /// 1 本のテストの環境（一時ディレクトリの HOME と、inbox に置いた入力）。
    struct Scene {
        let tmp: TempDirectory
        let layout: HomeLayout
        let input: URL
        let inputBytes: Data
        let inputSHA: String
        var slug: String { KeySlug.of(NormalizerTests.partkey) }
        var output: URL { layout.normalizedAudio(slug: slug) }
        var tmpOutput: URL { layout.normalizedAudioTmp(slug: slug) }

        init(_ blob: Data) throws {
            tmp = try TempDirectory()
            layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
            try layout.createDirectories()
            input = layout.inbox.appendingPathComponent(NormalizerTests.partkey, isDirectory: false)
            try FileManager.default.createDirectory(
                at: input.deletingLastPathComponent(), withIntermediateDirectories: true)
            try blob.write(to: input)
            inputBytes = blob
            inputSHA = SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined()
        }

        func exists(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }
    }

    static func run(_ s: Scene, duration: Double?, helper: String? = nil) async -> NormalizeOutcome {
        let req = NormalizeRequest(
            input: s.input, partkey: NormalizerTests.partkey, durationSeconds: duration,
            sha256Helper: helper ?? s.inputSHA, claimedBy: nil, duplicateOf: { _ in nil })
        return await Normalizer(config: NormalizerTests.defaults(), layout: s.layout, clock: SystemClock()).normalize(
            req)
    }

    @Test("F-77 ヘッダが実データより短い入力は、長さの照合を通っても NORMALIZE_VERIFY_FAILED。出力を消し、入力は書き換えない")
    func staleHeaderFailsAfterConversion() async throws {
        let s = try Scene(try HandMadeWAV.bwf(seconds: 2, declared: 144_000))
        // 登録時の長さ（AudioProbe）もヘッダから測るので 1 秒になる。出力も 1 秒なので、長さの照合だけでは通ってしまう
        #expect(AudioProbe.durationSeconds(of: s.input) == 1.0)
        let outcome = await Self.run(s, duration: 1.0)
        #expect(
            outcome
                == .failure(
                    StageFailure(
                        .normalizeVerifyFailed, "入力のヘッダの長さと実データの量が合いません（ヘッダ 48000 フレーム、実データ 96000 フレーム）")))
        #expect(!s.exists(s.output))
        #expect(!s.exists(s.tmpOutput))
        #expect(try Data(contentsOf: s.input) == s.inputBytes)
    }

    @Test("F-77 data のサイズが 0 の入力は NORMALIZE_VERIFY_FAILED")
    func zeroDataSizeFails() async throws {
        let s = try Scene(try HandMadeWAV.bwf(seconds: 2, declared: 0))
        #expect(AudioProbe.durationSeconds(of: s.input) == 0.0)
        let outcome = await Self.run(s, duration: 0.0)
        #expect(
            outcome
                == .failure(
                    StageFailure(
                        .normalizeVerifyFailed, "入力のヘッダの長さと実データの量が合いません（ヘッダ 0 フレーム、実データ 96000 フレーム）")))
        #expect(!s.exists(s.output))
        #expect(s.exists(s.input))
    }

    @Test("F-77 検証を通る出力が残っていても、入力のヘッダが短ければ再利用せず NORMALIZE_VERIFY_FAILED")
    func staleHeaderIsNotReused() async throws {
        let s = try Scene(try HandMadeWAV.bwf(seconds: 2, declared: 144_000))
        try FileManager.default.createDirectory(
            at: s.layout.stagingDirectory(slug: s.slug), withIntermediateDirectories: true)
        try BWFWriter.write(
            to: s.output, seconds: 1, format: .pcm16, content: .speech, minimalHeader: true, sampleRate: 16_000)
        #expect(OutputVerifier.verify(output: s.output, inputDuration: 1.0, tolerance: 1.0) == nil)
        let failure = try #require(NormalizerTests.failure(await Self.run(s, duration: 1.0)))
        #expect(failure.code == .normalizeVerifyFailed)
        #expect(!s.exists(s.output))
        #expect(s.exists(s.input))
    }

    @Test("F-77 コピー時の SHA と違えば SOURCE_HASH_MISMATCH が先（再コピーに回す）")
    func hashMismatchWinsOverStaleHeader() async throws {
        let s = try Scene(try HandMadeWAV.bwf(seconds: 2, declared: 144_000))
        let failure = try #require(
            NormalizerTests.failure(await Self.run(s, duration: 1.0, helper: String(repeating: "0", count: 64))))
        #expect(failure.code == .sourceHashMismatch)
        #expect(!s.exists(s.output))
        #expect(s.exists(s.input))
    }

    @Test("F-77 data の後ろに LIST が続く WAV は変換して合格し、2 回目は再利用する")
    func trailingListConvertsAndIsReused() async throws {
        let samples = try HandMadeWAV.pcm24Samples(seconds: 2)
        let s = try Scene(
            HandMadeWAV.riff(
                HandMadeWAV.fmtPCM24() + HandMadeWAV.dataHeader(declared: 288_000) + samples + HandMadeWAV.listChunk()))
        let first = try #require(NormalizerTests.success(await Self.run(s, duration: 2.0)))
        #expect(first.reused == false)
        #expect(first.sha256 == s.inputSHA)
        #expect(OutputVerifier.verify(output: s.output, inputDuration: 2.0, tolerance: 1.0) == nil)
        let second = try #require(NormalizerTests.success(await Self.run(s, duration: 2.0)))
        #expect(second.reused == true)
    }
}
