// inbox の原本 → 16 kHz WAV の手順（T-16 §6.4。PLAN §8.3）。入力は一時ディレクトリの BWF だけ。
import CryptoKit
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore

@testable import VDAudio

@Suite("Normalizer", .serialized)
struct NormalizerTests {
    static let partkey = "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
    static let other = "DJIMIC3/other/other_orig.wav"

    /// 1 本のテストの環境（一時ディレクトリの HOME と inbox の入力）。
    struct Fixture {
        let tmp: TempDirectory
        let layout: HomeLayout
        let input: URL
        let inputSHA: String
        let inputBytes: Data
        var slug: String { KeySlug.of(NormalizerTests.partkey) }
        var output: URL { layout.normalizedAudio(slug: slug) }
        var tmpOutput: URL { layout.normalizedAudioTmp(slug: slug) }
        var stagingDirectory: URL { layout.stagingDirectory(slug: slug) }

        init(
            seconds: Double = 2, format: BWFFormat = .pcm24, minimalHeader: Bool = false, sampleRate: Int = 48_000
        ) throws {
            tmp = try TempDirectory()
            layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
            try layout.createDirectories()
            input = layout.inbox.appendingPathComponent(NormalizerTests.partkey, isDirectory: false)
            try BWFWriter.write(
                to: input, seconds: seconds, format: format, content: .speech, minimalHeader: minimalHeader,
                sampleRate: sampleRate)
            inputBytes = try Data(contentsOf: input)
            inputSHA = SHA256.hash(data: inputBytes).map { String(format: "%02x", $0) }.joined()
        }

        func exists(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }
    }

    static func defaults() -> AudioConfig {
        AppConfig.defaults(timeZone: "Asia/Tokyo").audio
    }

    static func request(
        _ f: Fixture, duration: Double? = 2.0, helper: String?? = .none, claimedBy: String? = nil,
        duplicateOf: @escaping @Sendable (String) -> String? = { _ in nil }
    ) -> NormalizeRequest {
        NormalizeRequest(
            input: f.input, partkey: partkey, durationSeconds: duration, sha256Helper: helper ?? f.inputSHA,
            claimedBy: claimedBy, duplicateOf: duplicateOf)
    }

    static func run(
        _ f: Fixture, _ req: NormalizeRequest, config: AudioConfig = defaults(), clock: any AppClock = SystemClock()
    ) async -> NormalizeOutcome {
        await Normalizer(config: config, layout: f.layout, clock: clock).normalize(req)
    }

    static func failure(_ outcome: NormalizeOutcome) -> StageFailure? {
        if case .failure(let failure) = outcome { return failure }
        return nil
    }

    static func success(_ outcome: NormalizeOutcome) -> (sha256: String, inBytes: Int64, reused: Bool)? {
        if case .success(let sha, _, let inBytes, _, let reused) = outcome { return (sha, inBytes, reused) }
        return nil
    }

    /// 変換の成功の共通の確認（convertsPCM24 / convertsFloat32）。
    static func expectConverted(_ f: Fixture, _ outcome: NormalizeOutcome) throws {
        let result = try #require(success(outcome), "\(outcome)")
        #expect(result.reused == false)
        #expect(result.sha256 == f.inputSHA)
        #expect(result.inBytes == Int64(f.inputBytes.count))
        #expect(OutputVerifier.verify(output: f.output, inputDuration: 2.0, tolerance: 1.0) == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: f.stagingDirectory.path(percentEncoded: false))
        #expect(names == ["audio16k.wav"])
    }

    @Test("24 bit の BWF を 16 kHz に変換する")
    func convertsPCM24() async throws {
        let f = try Fixture(format: .pcm24)
        try Self.expectConverted(f, await Self.run(f, Self.request(f)))
    }

    @Test("32 bit float の BWF を変換する")
    func convertsFloat32() async throws {
        let f = try Fixture(format: .float32)
        try Self.expectConverted(f, await Self.run(f, Self.request(f)))
    }

    @Test("44 バイトヘッダの WAV も変換する")
    func convertsPCM16MinimalHeader() async throws {
        let f = try Fixture(format: .pcm16, minimalHeader: true, sampleRate: 48_000)
        #expect(Self.success(await Self.run(f, Self.request(f))) != nil)
    }

    @Test("出力は RIFF/WAVE")
    func outputIsRIFFWave() async throws {
        let f = try Fixture()
        _ = try #require(Self.success(await Self.run(f, Self.request(f))))
        let head = try Data(contentsOf: f.output).prefix(12)
        #expect(head.count == 12)
        #expect(Array(head[0..<4]) == Array("RIFF".utf8))
        #expect(Array(head[8..<12]) == Array("WAVE".utf8))
    }

    @Test("入力を書き換えない")
    func originalIsNeverTouched() async throws {
        let f = try Fixture()
        _ = try #require(Self.success(await Self.run(f, Self.request(f))))
        #expect(try Data(contentsOf: f.input) == f.inputBytes)
    }

    @Test("コピー時の SHA と違えば SOURCE_HASH_MISMATCH")
    func helperMismatchIsSourceHashMismatch() async throws {
        let f = try Fixture()
        let helper = String(repeating: "0", count: 64)
        let failure = try #require(Self.failure(await Self.run(f, Self.request(f, helper: .some(helper)))))
        #expect(failure.code == .sourceHashMismatch)
        #expect(failure.message.hasPrefix("再計算した SHA-256 がコピー時の値と一致しません（"))
        #expect(failure.message.hasSuffix("… ≠ 0000000000000000…）"))
        #expect(!f.exists(f.output))
        #expect(f.exists(f.input))
    }

    @Test("コピー時の SHA が無ければ不一致として扱う")
    func missingHelperIsMismatch() async throws {
        let f = try Fixture()
        let failure = try #require(Self.failure(await Self.run(f, Self.request(f, helper: .some(nil)))))
        #expect(failure.code == .sourceHashMismatch)
        #expect(failure.message.hasSuffix("… ≠ 記録なし）"))
    }

    @Test("長さが 1 秒を超えてずれると NORMALIZE_VERIFY_FAILED")
    func durationMismatchFailsVerification() async throws {
        let f = try Fixture(seconds: 2)
        let failure = try #require(Self.failure(await Self.run(f, Self.request(f, duration: 4.0))))
        #expect(failure.code == .normalizeVerifyFailed)
        #expect(failure.message.hasPrefix("長さが入力と "))
        #expect(!f.exists(f.output))
    }

    @Test("duration 不明なら長さを見ない")
    func unknownDurationSkipsLengthCheck() async throws {
        let f = try Fixture()
        #expect(Self.success(await Self.run(f, Self.request(f, duration: nil))) != nil)
    }

    @Test("slug の衝突は IMPORT_FAILED")
    func slugCollisionIsImportFailed() async throws {
        let f = try Fixture()
        let outcome = await Self.run(f, Self.request(f, claimedBy: Self.other))
        #expect(
            outcome
                == .failure(
                    StageFailure(
                        .importFailed, "staging の slug が衝突しています（\(f.slug) は DJIMIC3/other/other_orig.wav が使用中）")))
    }

    @Test("自分の claim は衝突ではない")
    func ownClaimIsNotCollision() async throws {
        let f = try Fixture()
        #expect(Self.success(await Self.run(f, Self.request(f, claimedBy: Self.partkey))) != nil)
    }

    @Test("同じ SHA の別の Part があれば重複")
    func duplicateContentIsReported() async throws {
        let f = try Fixture()
        let outcome = await Self.run(f, Self.request(f, duplicateOf: { _ in NormalizerTests.other }))
        #expect(outcome == .duplicate(of: "DJIMIC3/other/other_orig.wav", sha256: f.inputSHA))
        #expect(!f.exists(f.output))
        #expect(f.exists(f.input))
    }

    @Test("自分の SHA は重複ではない")
    func ownSHAIsNotDuplicate() async throws {
        let f = try Fixture()
        #expect(Self.success(await Self.run(f, Self.request(f, duplicateOf: { _ in NormalizerTests.partkey }))) != nil)
    }

    @Test("検証を通る出力は再利用する")
    func verifiedOutputIsReused() async throws {
        let f = try Fixture()
        let first = try #require(Self.success(await Self.run(f, Self.request(f))))
        #expect(first.reused == false)
        let second = try #require(Self.success(await Self.run(f, Self.request(f))))
        #expect(second.reused == true)
        #expect(second.sha256 == f.inputSHA)
        #expect(second.inBytes == Int64(f.inputBytes.count))
    }

    @Test("再利用でもコピー時の SHA と照合する")
    func reusePathChecksHash() async throws {
        let f = try Fixture()
        _ = try #require(Self.success(await Self.run(f, Self.request(f))))
        let helper = String(repeating: "f", count: 64)
        let failure = try #require(Self.failure(await Self.run(f, Self.request(f, helper: .some(helper)))))
        #expect(failure.code == .sourceHashMismatch)
        #expect(!f.exists(f.output))
    }

    @Test("再利用でも重複を判定する")
    func reusePathChecksDuplicate() async throws {
        let f = try Fixture()
        _ = try #require(Self.success(await Self.run(f, Self.request(f))))
        let outcome = await Self.run(f, Self.request(f, duplicateOf: { _ in NormalizerTests.other }))
        #expect(outcome == .duplicate(of: "DJIMIC3/other/other_orig.wav", sha256: f.inputSHA))
        #expect(!f.exists(f.output))
    }

    @Test("壊れた出力は作り直す")
    func brokenOutputIsRegenerated() async throws {
        let f = try Fixture()
        try FileManager.default.createDirectory(at: f.stagingDirectory, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: f.output)
        let result = try #require(Self.success(await Self.run(f, Self.request(f))))
        #expect(result.reused == false)
        #expect(OutputVerifier.verify(output: f.output, inputDuration: 2.0, tolerance: 1.0) == nil)
    }

    @Test("入力が無ければ IMPORT_FAILED")
    func missingInputIsImportFailed() async throws {
        let f = try Fixture()
        let req = NormalizeRequest(
            input: f.layout.inbox.appendingPathComponent("DJIMIC3/none/none_orig.wav"), partkey: Self.partkey,
            durationSeconds: 2.0, sha256Helper: f.inputSHA, claimedBy: nil, duplicateOf: { _ in nil })
        let failure = try #require(Self.failure(await Self.run(f, req)))
        #expect(failure.code == .importFailed)
        #expect(!f.exists(f.tmpOutput))
        #expect(!f.exists(f.output))
    }

    @Test("0 バイトの入力は IMPORT_FAILED")
    func emptyInputIsImportFailed() async throws {
        let f = try Fixture()
        try Data().write(to: f.input)
        let empty = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        let failure = try #require(
            Self.failure(await Self.run(f, Self.request(f, duration: nil, helper: .some(empty)))))
        #expect(failure.code == .importFailed)
        #expect(!f.exists(f.tmpOutput))
        #expect(!f.exists(f.output))
        #expect(f.exists(f.input))
    }

    @Test("空きが足りなければ DISK_SPACE_LOW")
    func diskSpaceLowIsReported() async throws {
        let f = try Fixture()
        var config = Self.defaults()
        config.freeSpaceMarginBytes = Int(Int64.max / 4)
        let failure = try #require(Self.failure(await Self.run(f, Self.request(f), config: config)))
        #expect(failure.code == .diskSpaceLow)
        #expect(!f.exists(f.output))
        #expect(f.exists(f.input))
    }

    @Test("時間上限を超えたら中断して IMPORT_FAILED")
    func deadlineExceededIsImportFailed() async throws {
        let f = try Fixture()
        let clock = SteppingClock(start: Instant(epochMillis: 0), stepMilliseconds: 1_000_000)
        let outcome = await Self.run(f, Self.request(f, duration: nil), clock: clock)
        #expect(outcome == .failure(StageFailure(.importFailed, "180 秒を超えました")))
        #expect(!f.exists(f.tmpOutput))
        #expect(!f.exists(f.output))
    }

    @Test(
        "時間上限の式",
        arguments: [
            (Double?.none, 180), (100, 180), (360, 180), (361, 180), (1800.7, 900),
        ] as [(Double?, Int)])
    func timeoutTable(duration: Double?, expected: Int) {
        #expect(Normalizer.timeoutSeconds(duration: duration, config: Self.defaults()) == expected)
    }

    @Test("CE audio.timeoutFactor を 2.0 にすると時間上限が伸びる")
    func ceAudioTimeoutFactor() {
        var config = Self.defaults()
        #expect(Normalizer.timeoutSeconds(duration: 1800.7, config: config) == 900)
        config.timeoutFactor = 2.0
        #expect(Normalizer.timeoutSeconds(duration: 1800.7, config: config) == 3601)
    }

    @Test("CE audio.minTimeoutSeconds が時間上限の下限")
    func ceAudioMinTimeoutSeconds() {
        var config = Self.defaults()
        #expect(Normalizer.timeoutSeconds(duration: nil, config: config) == 180)
        #expect(Normalizer.timeoutSeconds(duration: 100, config: config) == 180)
        config.minTimeoutSeconds = 600
        #expect(Normalizer.timeoutSeconds(duration: nil, config: config) == 600)
        #expect(Normalizer.timeoutSeconds(duration: 100, config: config) == 600)
    }

    @Test("CE audio.durationToleranceSeconds 許容を広げると検証を通る")
    func ceDurationToleranceSeconds() async throws {
        let f = try Fixture(seconds: 2)
        var config = Self.defaults()
        config.durationToleranceSeconds = 3.0
        #expect(Self.success(await Self.run(f, Self.request(f, duration: 4.0), config: config)) != nil)
    }

    @Test("Int に収まらない長さでも時間上限はトラップしない")
    func hugeDurationTimeoutSaturates() {
        #expect(Normalizer.timeoutSeconds(duration: .infinity, config: Self.defaults()) == Int.max)
        #expect(Normalizer.timeoutSeconds(duration: 1e300, config: Self.defaults()) == Int.max)
    }
}
