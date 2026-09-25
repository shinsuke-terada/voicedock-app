// 入力の WAV のヘッダの長さと実データの量の照合（PLAN §8.3 手順 6。F-77・issue #117）。一時ディレクトリの WAV だけを使う。
import Foundation
import TestSupport
import Testing

@testable import VDAudio

@Suite("InputExtentCheck")
struct InputExtentCheckTests {
    static let mismatchHalf = "入力のヘッダの長さと実データの量が合いません（ヘッダ 48000 フレーム、実データ 96000 フレーム）"

    static func check(_ blob: Data, _ tmp: TempDirectory) throws -> String? {
        InputExtentCheck.check(input: try HandMadeWAV.write(blob, named: "in.wav", in: tmp))
    }

    static func layout(_ blob: Data, _ tmp: TempDirectory) throws -> InputExtentCheck.Layout {
        try InputExtentCheck.readLayout(try HandMadeWAV.write(blob, named: "in.wav", in: tmp))
    }

    @Test("F-77 ヘッダどおりの実機と同じ BWF は合格", arguments: BWFFormat.allCases)
    func bwfAsWrittenPasses(format: BWFFormat) throws {
        let tmp = try TempDirectory()
        let url = try BWFWriter.write(
            to: tmp.url.appendingPathComponent("bwf.wav"), seconds: 1, format: format, content: .speech)
        #expect(InputExtentCheck.check(input: url) == nil)
    }

    @Test("F-77 44 バイトヘッダの WAV も合格")
    func minimalHeaderPasses() throws {
        let tmp = try TempDirectory()
        let url = try BWFWriter.write(
            to: tmp.url.appendingPathComponent("min.wav"), seconds: 1, format: .pcm16, content: .speech,
            minimalHeader: true, sampleRate: 16_000)
        #expect(InputExtentCheck.check(input: url) == nil)
    }

    @Test("F-77 実機と同じ BWF の data は 32776 から、宣言どおりの量")
    func bwfLayout() throws {
        let tmp = try TempDirectory()
        let blob = try BWFWriter.build(seconds: 1, format: .pcm24, content: .speech)
        #expect(
            try Self.layout(blob, tmp)
                == InputExtentCheck.Layout(
                    dataStart: 32_776, declaredBytes: 144_000, fileBytes: 176_776, actualBytes: 144_000))
    }

    @Test(
        "F-77 data のサイズが実データより小さい（ヘッダが古い）と不合格",
        arguments: [(BWFFormat.pcm24, UInt32(144_000)), (.float32, 192_000), (.pcm16, 96_000)])
    func staleDataSizeFails(format: BWFFormat, declared: UInt32) throws {
        let tmp = try TempDirectory()
        let blob = try HandMadeWAV.bwf(seconds: 2, format: format, declared: declared)
        #expect(try Self.check(blob, tmp) == Self.mismatchHalf)
    }

    @Test("F-77 ヘッダが古い BWF の実データは data の開始位置からファイルの終わりまで")
    func staleDataSizeLayout() throws {
        let tmp = try TempDirectory()
        let blob = try HandMadeWAV.bwf(seconds: 2, declared: 144_000)
        #expect(
            try Self.layout(blob, tmp)
                == InputExtentCheck.Layout(
                    dataStart: 32_776, declaredBytes: 144_000, fileBytes: 320_776, actualBytes: 288_000))
    }

    @Test("F-77 data のサイズが 0（ヘッダ未確定）で実データがあると不合格")
    func zeroDataSizeFails() throws {
        let tmp = try TempDirectory()
        let blob = try HandMadeWAV.bwf(seconds: 2, declared: 0)
        #expect(
            try Self.check(blob, tmp) == "入力のヘッダの長さと実データの量が合いません（ヘッダ 0 フレーム、実データ 96000 フレーム）")
    }

    @Test("F-77 実データが 1 フレームだけ多くても不合格")
    func oneExtraFrameFails() throws {
        let tmp = try TempDirectory()
        let blob = try HandMadeWAV.bwf(seconds: 2, declared: 287_997)
        #expect(
            try Self.check(blob, tmp)
                == "入力のヘッダの長さと実データの量が合いません（ヘッダ 95999 フレーム、実データ 96000 フレーム）")
    }

    @Test("F-77 1 フレームに満たない余り（2 バイト）は合格")
    func subFrameRemainderPasses() throws {
        let tmp = try TempDirectory()
        var blob = try BWFWriter.build(seconds: 2, format: .pcm24, content: .speech)
        blob.append(Data([0x01, 0x02]))
        #expect(try Self.check(blob, tmp) == nil)
    }

    @Test("F-77 data の後ろに LIST チャンクが続く正常なファイルは合格（実データは宣言どおり）")
    func trailingListPasses() throws {
        let tmp = try TempDirectory()
        let samples = try HandMadeWAV.pcm24Samples(seconds: 2)
        let blob = HandMadeWAV.riff(
            HandMadeWAV.fmtPCM24() + HandMadeWAV.dataHeader(declared: 288_000) + samples + HandMadeWAV.listChunk())
        #expect(try Self.check(blob, tmp) == nil)
        #expect(
            try Self.layout(blob, tmp)
                == InputExtentCheck.Layout(
                    dataStart: 44, declaredBytes: 288_000, fileBytes: 288_070, actualBytes: 288_000))
    }

    @Test("F-77 LIST が続いていても data のサイズが小さければ、後ろ全部を実データとして数えて不合格")
    func trailingListWithStaleSizeFails() throws {
        let tmp = try TempDirectory()
        let samples = try HandMadeWAV.pcm24Samples(seconds: 2)
        let blob = HandMadeWAV.riff(
            HandMadeWAV.fmtPCM24() + HandMadeWAV.dataHeader(declared: 144_000) + samples + HandMadeWAV.listChunk())
        #expect(
            try Self.check(blob, tmp)
                == "入力のヘッダの長さと実データの量が合いません（ヘッダ 48000 フレーム、実データ 96008 フレーム）")
    }

    @Test("F-77 data より前に奇数長のチャンク（パッド 1 バイトつき）があっても data を見つけて合格")
    func oddChunkBeforeDataPasses() throws {
        let tmp = try TempDirectory()
        let samples = try HandMadeWAV.pcm24Samples(seconds: 2)
        let blob = HandMadeWAV.riff(
            HandMadeWAV.fmtPCM24() + HandMadeWAV.chunk("note", Data("VDock".utf8))
                + HandMadeWAV.dataHeader(declared: 288_000) + samples)
        #expect(try Self.check(blob, tmp) == nil)
        #expect(
            try Self.layout(blob, tmp)
                == InputExtentCheck.Layout(
                    dataStart: 58, declaredBytes: 288_000, fileBytes: 288_058, actualBytes: 288_000))
    }

    @Test("F-77 data が奇数長（24 bit mono の奇数フレーム）で終わりにパッド 1 バイトがあれば合格、実データは宣言どおり")
    func oddDataWithPadPasses() throws {
        let tmp = try TempDirectory()
        let samples = try HandMadeWAV.pcm24Samples(frames: 48_001)
        try #require(samples.count == 144_003)
        let blob = HandMadeWAV.riff(
            HandMadeWAV.fmtPCM24() + HandMadeWAV.dataHeader(declared: 144_003) + samples + Data([0x00]))
        #expect(try Self.check(blob, tmp) == nil)
        #expect(
            try Self.layout(blob, tmp)
                == InputExtentCheck.Layout(
                    dataStart: 44, declaredBytes: 144_003, fileBytes: 144_048, actualBytes: 144_003))
    }

    @Test("F-77 data のサイズがファイルより大きい（末尾が欠けた）ものはこの照合では落とさない")
    func declaredBeyondFileIsLeftToLengthCheck() throws {
        let tmp = try TempDirectory()
        let blob = try HandMadeWAV.bwf(seconds: 2, declared: 576_000)
        #expect(try Self.check(blob, tmp) == nil)
    }

    @Test("F-77 RIFF の data のサイズが 0xFFFFFFFF（不明）ならファイルの終わりまで読めるので合格")
    func unknownDataSizePasses() throws {
        let tmp = try TempDirectory()
        let blob = try HandMadeWAV.bwf(seconds: 2, declared: 0xFFFF_FFFF)
        #expect(try Self.check(blob, tmp) == nil)
    }

    @Test("F-77 RF64 は ds64 の dataSize を宣言したサイズとして読む")
    func rf64UsesDS64() throws {
        let tmp = try TempDirectory()
        let samples = try HandMadeWAV.pcm24Samples(seconds: 2)
        let body =
            HandMadeWAV.ds64(riffSize: 288_072, dataSize: 288_000, sampleCount: 96_000) + HandMadeWAV.fmtPCM24()
            + HandMadeWAV.dataHeader(declared: 0xFFFF_FFFF) + samples
        let blob = HandMadeWAV.riff(body, form: "RF64", size: 0xFFFF_FFFF)
        #expect(try Self.check(blob, tmp) == nil)
        #expect(
            try Self.layout(blob, tmp)
                == InputExtentCheck.Layout(
                    dataStart: 80, declaredBytes: 288_000, fileBytes: 288_080, actualBytes: 288_000))
    }

    @Test("F-77 RF64 に ds64 が無ければ構造を読めない")
    func rf64WithoutDS64IsUnreadable() throws {
        let tmp = try TempDirectory()
        let samples = try HandMadeWAV.pcm24Samples(seconds: 1)
        let blob = HandMadeWAV.riff(
            HandMadeWAV.fmtPCM24() + HandMadeWAV.dataHeader(declared: 0xFFFF_FFFF) + samples, form: "RF64",
            size: 0xFFFF_FFFF)
        #expect(try Self.check(blob, tmp) == "入力の WAV の構造を読めません（RF64 に ds64 チャンクがありません）")
    }

    @Test("F-77 拡張 fmt（WAVE_FORMAT_EXTENSIBLE）でも照らす")
    func extensibleFormat() throws {
        let tmp = try TempDirectory()
        let samples = try HandMadeWAV.pcm24Samples(seconds: 2)
        let good = HandMadeWAV.riff(
            HandMadeWAV.fmtExtensiblePCM24() + HandMadeWAV.dataHeader(declared: 288_000) + samples)
        #expect(try Self.check(good, tmp) == nil)
        let stale = HandMadeWAV.riff(
            HandMadeWAV.fmtExtensiblePCM24() + HandMadeWAV.dataHeader(declared: 144_000) + samples)
        #expect(try Self.check(stale, tmp) == Self.mismatchHalf)
    }

    @Test("F-77 0 バイトの入力は構造を読めない")
    func emptyInputIsUnreadable() throws {
        let tmp = try TempDirectory()
        #expect(try Self.check(Data(), tmp) == "入力の WAV の構造を読めません（RIFF / RF64 の WAVE ではありません）")
    }

    @Test("F-77 WAV でなければ構造を読めない")
    func garbageIsUnreadable() throws {
        let tmp = try TempDirectory()
        #expect(
            try Self.check(Data("not a wav".utf8), tmp) == "入力の WAV の構造を読めません（RIFF / RF64 の WAVE ではありません）")
    }

    @Test("F-77 data チャンクが無ければ構造を読めない")
    func missingDataChunkIsUnreadable() throws {
        let tmp = try TempDirectory()
        #expect(
            try Self.check(HandMadeWAV.riff(HandMadeWAV.fmtPCM24()), tmp) == "入力の WAV の構造を読めません（data チャンクがありません）")
    }

    @Test("F-77 無いファイルは構造を読めない")
    func missingFileIsUnreadable() throws {
        let tmp = try TempDirectory()
        let message = try #require(InputExtentCheck.check(input: tmp.url.appendingPathComponent("none.wav")))
        #expect(message.hasPrefix("入力の WAV の構造を読めません（"))
        #expect(message.hasSuffix("）"))
    }
}
