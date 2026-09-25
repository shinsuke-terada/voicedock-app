// 16 kHz 出力の検証の順と文言（T-16 §6.3。PLAN §8.3 手順 6、ASR-01）。
import Foundation
import TestSupport
import Testing

@testable import VDAudio

@Suite("OutputVerifier")
struct OutputVerifierTests {
    /// 16 kHz / s16 / 1 ch / 1.0 秒ちょうどの見本。
    private static func sample(_ tmp: TempDirectory) throws -> URL {
        try BWFWriter.write(
            to: tmp.url.appendingPathComponent("audio16k.wav"), seconds: 1, format: .pcm16, content: .speech,
            minimalHeader: true, sampleRate: 16_000)
    }

    @Test("16 kHz / s16 / mono は合格")
    func validOutputPasses() throws {
        let tmp = try TempDirectory()
        let url = try Self.sample(tmp)
        #expect(OutputVerifier.verify(output: url, inputDuration: 1.0, tolerance: 1.0) == nil)
    }

    @Test("無い出力")
    func missingOutput() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("none.wav")
        let path = url.path(percentEncoded: false)
        #expect(OutputVerifier.verify(output: url, inputDuration: 1.0, tolerance: 1.0) == "\(path) がありません")
    }

    @Test("0 バイト")
    func emptyOutput() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("empty.wav")
        try Data().write(to: url)
        let path = url.path(percentEncoded: false)
        #expect(OutputVerifier.verify(output: url, inputDuration: 1.0, tolerance: 1.0) == "\(path) が 0 バイトです")
    }

    @Test("音声として読めない")
    func unreadableOutput() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("garbage.wav")
        try Data("not a wav".utf8).write(to: url)
        let message = try #require(OutputVerifier.verify(output: url, inputDuration: 1.0, tolerance: 1.0))
        #expect(message.hasPrefix("出力を読めません: "))
    }

    @Test("48 kHz は不合格")
    func wrongSampleRate() throws {
        let tmp = try TempDirectory()
        let url = try BWFWriter.write(
            to: tmp.url.appendingPathComponent("48k.wav"), seconds: 1, format: .pcm16, content: .speech,
            minimalHeader: true, sampleRate: 48_000)
        #expect(
            OutputVerifier.verify(output: url, inputDuration: 1.0, tolerance: 1.0) == "sample_rate が 48000（期待 16000）")
    }

    @Test("24 bit は不合格")
    func wrongSampleFormat() throws {
        let tmp = try TempDirectory()
        let url = try BWFWriter.write(
            to: tmp.url.appendingPathComponent("24bit.wav"), seconds: 1, format: .pcm24, content: .speech,
            minimalHeader: true, sampleRate: 16_000)
        let message = try #require(OutputVerifier.verify(output: url, inputDuration: 1.0, tolerance: 1.0))
        #expect(message.hasPrefix("sample_fmt が "))
        #expect(message.hasSuffix("（期待 s16）"))
    }

    @Test("入力の長さが不明なら長さを見ない")
    func unknownInputDurationSkipsLength() throws {
        let tmp = try TempDirectory()
        let url = try Self.sample(tmp)
        #expect(OutputVerifier.verify(output: url, inputDuration: nil, tolerance: 1.0) == nil)
    }

    @Test("ずれが 1.0 ちょうどは合格")
    func gapExactlyToleranceIsAccepted() throws {
        let tmp = try TempDirectory()
        let url = try Self.sample(tmp)
        #expect(OutputVerifier.verify(output: url, inputDuration: 2.0, tolerance: 1.0) == nil)
    }

    @Test("ずれが 1.0 を超えると不合格")
    func gapOverToleranceFails() throws {
        let tmp = try TempDirectory()
        let url = try Self.sample(tmp)
        #expect(
            OutputVerifier.verify(output: url, inputDuration: 2.001, tolerance: 1.0)
                == "長さが入力と 1.00 秒ずれています（許容 1.0 秒）")
    }

    @Test("ディレクトリは無い出力として扱う")
    func directoryIsMissing() throws {
        let tmp = try TempDirectory()
        let path = tmp.url.path(percentEncoded: false)
        #expect(OutputVerifier.verify(output: tmp.url, inputDuration: 1.0, tolerance: 1.0) == "\(path) がありません")
    }

    @Test("sample_fmt の名前の表")
    func sampleFormatNames() {
        #expect(OutputVerifier.sampleFormatName(.pcmFormatInt16) == "s16")
        #expect(OutputVerifier.sampleFormatName(.pcmFormatInt32) == "s32")
        #expect(OutputVerifier.sampleFormatName(.pcmFormatFloat32) == "flt")
        #expect(OutputVerifier.sampleFormatName(.pcmFormatFloat64) == "dbl")
        #expect(OutputVerifier.sampleFormatName(.otherFormat) == "other")
    }
}
