// 偽物の BWF そのもののテスト（TEST-05。T-14 §5.6）。期待値は voicedock@d3d595e の make_wav.build_wav を Python 3.12 で実行して得たもの。
import Foundation
import TestSupport
import Testing
import VDCore

@Suite("BWFWriter")
struct BWFWriterTests {
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    @Test("pcm24 の発話 1 秒が voicedock の make_wav と同じバイト列")
    func pcm24SpeechMatchesVoicedock() throws {
        let blob = try BWFWriter.build(seconds: 1, format: .pcm24, content: .speech)
        #expect(blob.count == 176_776)
        #expect(FileHasher.sha256(blob) == "e16eb9a53426118828d9d98c50caa3c4722db560e0c7d7bba81f236461fcc728")
    }

    @Test("float32 の発話 1 秒が同じバイト列")
    func float32SpeechMatchesVoicedock() throws {
        let blob = try BWFWriter.build(seconds: 1, format: .float32, content: .speech)
        #expect(blob.count == 224_776)
        #expect(FileHasher.sha256(blob) == "b4873fc20687d19a1f16a79e6e7717b1cf8757f10b4f4f94f5a4803829c5e6aa")
    }

    @Test("16 kHz の pcm16 が同じバイト列")
    func pcm16At16kMatchesVoicedock() throws {
        let blob = try BWFWriter.build(seconds: 1, format: .pcm16, content: .speech, sampleRate: 16_000)
        #expect(blob.count == 64_776)
        #expect(FileHasher.sha256(blob) == "247a2cb88f5df09f85617402fa9f4550ce1201d4f4e47e5948afdbdaa97ee00a")
    }

    @Test("44 バイトヘッダの無音が同じバイト列")
    func minimalHeaderMatchesVoicedock() throws {
        let blob = try BWFWriter.build(seconds: 0.5, format: .pcm24, content: .silence, minimalHeader: true)
        #expect(blob.count == 72_044)
        #expect(FileHasher.sha256(blob) == "5fc6724ed1e828f823fb78ac79c4217d8551f0540fb2d9717b078ee752bc8cc3")
    }

    @Test("2 秒の無音が同じバイト列")
    func pcm24SilenceTwoSecondsMatchesVoicedock() throws {
        let blob = try BWFWriter.build(seconds: 2, format: .pcm24, content: .silence)
        #expect(blob.count == 320_776)
        #expect(FileHasher.sha256(blob) == "7b7dc0e1f420b6d4b524d0f5fc0112d353c12fd1d198c4c69e4ec20ae6671240")
    }

    @Test("data の開始が 32776")
    func dataStartsAtBWFOffset() throws {
        let blob = try BWFWriter.build(seconds: 1, format: .pcm24, content: .speech)
        #expect(blob.subdata(in: 32_768..<32_772) == Data("data".utf8))
        #expect(
            Self.hex(blob.subdata(in: 32_776..<32_800)) == "000000d21a01003402ed4903005b04b265058b6806296207")
    }

    @Test("先頭 48 バイトが voicedock と同じ")
    func headerBytes() throws {
        let blob = try BWFWriter.build(seconds: 1, format: .pcm24, content: .silence)
        #expect(
            Self.hex(blob.prefix(48))
                == "5249464680b2020057415645666d7420100000000100010080bb00008032020003001800626578745a02000000000000")
    }

    @Test("チャンクの並びと大きさ")
    func chunkOrder() throws {
        let blob = try BWFWriter.build(seconds: 1, format: .pcm24)
        var chunks: [(String, Int)] = []
        var offset = 12
        while offset + 8 <= blob.count {
            let id = String(decoding: blob.subdata(in: offset..<(offset + 4)), as: UTF8.self)
            let size = blob.subdata(in: (offset + 4)..<(offset + 8)).enumerated().reduce(0) { sum, pair in
                sum | (Int(pair.element) << (8 * pair.offset))
            }
            chunks.append((id, size))
            offset += 8 + size + (size % 2)
        }
        #expect(chunks.map(\.0) == ["fmt ", "bext", "iXML", "cue ", "PAD ", "data"])
        #expect(chunks.prefix(5).map(\.1) == [16, 602, 1092, 28, 30_978])
    }

    @Test("0 秒は作らない")
    func rejectsNonPositiveSeconds() {
        #expect(throws: BWFError.nonPositiveSeconds) { try BWFWriter.build(seconds: 0) }
    }
}
