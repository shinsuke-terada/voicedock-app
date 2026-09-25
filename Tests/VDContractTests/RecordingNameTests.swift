// RecordingName の検査（T-06 §5.3）。
import Foundation
import TestSupport
import Testing

@testable import VDContract

@Suite("RecordingName")
struct RecordingNameTests {
    @Test("denoised の名前を読む")
    func parsesDenoisedName() throws {
        let parsed = try #require(RecordingName.parseFile("TX01_MIC002_20260829_071204.wav"))
        #expect(parsed.transmitterID == "TX01")
        #expect(parsed.micIndex == 2)
        #expect(parsed.local.year == 2026)
        #expect(parsed.local.month == 8)
        #expect(parsed.local.day == 29)
        #expect(parsed.local.hour == 7)
        #expect(parsed.local.minute == 12)
        #expect(parsed.local.second == 4)
        #expect(parsed.isOrig == false)
        #expect(parsed.ext == "wav")
    }

    @Test("_orig の名前を読む")
    func parsesOrigName() throws {
        let parsed = try #require(RecordingName.parseFile("TX01_MIC002_20260829_071204_orig.wav"))
        #expect(parsed.isOrig == true)
        #expect(parsed.ext == "wav")
    }

    @Test("拡張子の大文字を受ける")
    func acceptsUppercaseExtension() throws {
        let denoised = try #require(RecordingName.parseFile("TX01_MIC002_20260829_071204.WAV"))
        #expect(denoised.ext == "WAV")
        #expect(denoised.isOrig == false)
        let orig = try #require(RecordingName.parseFile("TX01_MIC002_20260829_071204_orig.WAV"))
        #expect(orig.ext == "WAV")
        #expect(orig.isOrig == true)
    }

    @Test("境界値と実機の名前")
    func acceptsBoundaryNumbers() throws {
        let low = try #require(RecordingName.parseFile("TX00_MIC000_20260829_071204_orig.wav"))
        #expect(low.transmitterID == "TX00")
        #expect(low.micIndex == 0)
        let high = try #require(RecordingName.parseFile("TX99_MIC999_20260829_071204_orig.wav"))
        #expect(high.transmitterID == "TX99")
        #expect(high.micIndex == 999)
        let real = try #require(RecordingName.parseFile("TX00_MIC001_20260912_120950_orig.wav"))
        #expect(real.micIndex == 1)
        #expect(real.local.dayStamp == "20260912")
    }

    @Test(
        "規則外の名前は nil（パラメータ化）",
        arguments: [
            "TX1_MIC002_20260829_071204.wav",
            "TX001_MIC002_20260829_071204.wav",
            "TX01_MIC02_20260829_071204.wav",
            "TX01_MIC0002_20260829_071204.wav",
            "TX01_MIC002_2026082_071204.wav",
            "TX01_MIC002_20260829_07120.wav",
            "TX01_MIC002_20260829_071204.mp3",
            "TX01_MIC002_20260829_071204_ORIG.wav",
            "TX01_MIC002_20260829_071204_orig_orig.wav",
            "TX01_MIC002_20260829_071204_orig.Wav",
            "._TX01_MIC002_20260829_071204_orig.wav",
            "prefix_TX01_MIC002_20260829_071204_orig.wav",
            "TX01_MIC002_20260829_071204_orig.wav.partial",
            "TX01_MIC002_20260829_071204_orig.wav.meta.json",
            "TX01_MIC002_20260829_071204_orig.wav\n",
            "TX01_MIC002_２0260829_071204_orig.wav",
            "",
        ])
    func rejectsMalformedNames(_ name: String) {
        #expect(RecordingName.parseFile(name) == nil)
        // 形そのものが規則外（全角数字は `Int(_:)` でも落ちるので、形の判定も見て `\d` への置き換えを捕まえる）
        #expect(!RecordingName.matchesFilePattern(name))
    }

    @Test(
        "存在しない日時は例外にせず nil",
        arguments: [
            "TX01_MIC002_20260230_071204_orig.wav",
            "TX01_MIC002_20261301_071204_orig.wav",
            "TX01_MIC002_20260829_251204_orig.wav",
            "TX01_MIC002_20260829_076104_orig.wav",
            "TX01_MIC002_00000000_000000_orig.wav",
        ])
    func rejectsImpossibleDates(_ name: String) {
        #expect(RecordingName.parseFile(name) == nil)
    }

    @Test("形だけの判定は日時を見ない")
    func matchesFilePatternIgnoresDate() {
        #expect(RecordingName.matchesFilePattern("TX01_MIC002_20260230_071204_orig.wav"))
        #expect(RecordingName.parseFile("TX01_MIC002_20260230_071204_orig.wav") == nil)
        #expect(RecordingName.matchesFilePattern("TX01_MIC002_20260829_071204.wav"))
        #expect(!RecordingName.matchesFilePattern("TX01_MIC002_20260829_071204_orig.wav.partial"))
        #expect(!RecordingName.matchesFilePattern("TX01_MIC002_20260829_071204_orig.wav\n"))
    }

    @Test("時刻はファイル名のまま（TIME-03）")
    func timeIsAttachedNotConverted() throws {
        let parsed = try #require(RecordingName.parseFile("TX01_MIC002_20260829_071204_orig.wav"))
        #expect(parsed.local.hour == 7)
        #expect(parsed.local.minute == 12)
    }

    @Test("フォルダ名の規則")
    func folderRule() {
        #expect(RecordingName.isFolder("TX_MIC001_20260829_071201"))
        #expect(!RecordingName.isFolder("TX_MIC01_20260829_071201"))
        #expect(!RecordingName.isFolder("TX01_MIC001_20260829_071201"))
        #expect(!RecordingName.isFolder("TX_MIC001_20260829_071201_x"))
        #expect(!RecordingName.isFolder("tx_MIC001_20260829_071201"))
        #expect(!RecordingName.isFolder(".TX_MIC001_20260829_071201"))
        #expect(!RecordingName.isFolder("TX_MIC001_20260829_071201\n"))
        #expect(!RecordingName.isFolder(""))
        #expect(RecordingName.isFolder("TX_MIC001_20260230_071201"))
    }

    @Test("正規表現の文字列が PLAN §4.1 と逐語で同じ")
    func patternsAreVerbatim() {
        #expect(RecordingName.filePattern == #"^(TX[0-9]{2})_(MIC[0-9]{3})_([0-9]{8})_([0-9]{6})(_orig)?\.(wav|WAV)$"#)
        #expect(RecordingName.folderPattern == #"^TX_(MIC[0-9]{3})_([0-9]{8})_([0-9]{6})$"#)
    }
}
