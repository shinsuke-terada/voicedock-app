// AudioProbe の長さの測定（T-14 §5.5）。一時ディレクトリの BWF だけを使う。
import Foundation
import TestSupport
import Testing
import VDAudio

@Suite("AudioProbe")
struct AudioProbeTests {
    @Test("48 kHz 24 bit の BWF の長さ")
    func pcm24Duration() throws {
        let tmp = try TempDirectory()
        let url = try BWFWriter.write(
            to: tmp.url.appendingPathComponent("a.wav"), seconds: 1.5, format: .pcm24, content: .speech)
        let seconds = try #require(AudioProbe.durationSeconds(of: url))
        #expect(abs(seconds - 1.5) <= 0.000_001)
    }

    @Test("32 bit float の BWF の長さ")
    func float32Duration() throws {
        let tmp = try TempDirectory()
        let url = try BWFWriter.write(
            to: tmp.url.appendingPathComponent("f.wav"), seconds: 2.0, format: .float32, content: .speech)
        #expect(AudioProbe.durationSeconds(of: url) == 2.0)
    }

    @Test("44 バイトヘッダ・16 kHz の長さ")
    func minimalHeaderPCM16() throws {
        let tmp = try TempDirectory()
        let url = try BWFWriter.write(
            to: tmp.url.appendingPathComponent("m.wav"), seconds: 1.0, format: .pcm16, minimalHeader: true,
            sampleRate: 16_000)
        #expect(AudioProbe.durationSeconds(of: url) == 1.0)
    }

    @Test("WAV でなければ nil")
    func garbageIsNil() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("g.wav")
        try Data("not a wav".utf8).write(to: url)
        #expect(AudioProbe.durationSeconds(of: url) == nil)
    }

    @Test("無いファイルは nil")
    func missingIsNil() throws {
        let tmp = try TempDirectory()
        #expect(AudioProbe.durationSeconds(of: tmp.url.appendingPathComponent("missing.wav")) == nil)
    }
}
