// partkey の分解と device_id の健全性を Unicode スカラーで見る（PLAN §4.2・F-81・issue #119）。
// ASCII の入力の結果は 1 文字も変わらず、結合文字の入力では以前（書記素）は通ったものが通らない（厳しくなる側だけ）。
import Foundation
import Testing

@testable import VDContract

@Suite("PartKey と DeviceID のスカラー単位の判定（F-81）")
struct KeyScalarTests {
    /// PLAN §4.2 の固定値
    static let fixedPartkey = "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
    static let fixedRelpath = "TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"

    /// スカラー列で比べるための写し（Swift の == は正準等価なので使わない）
    static func scalars(_ s: String?) -> [Unicode.Scalar]? {
        s.map { Array($0.unicodeScalars) }
    }

    @Test("F-81 ASCII の partkey の分解は変わらない（最初の / の前と後）")
    func asciiPartkeySplitIsUnchanged() {
        #expect(PartKey.deviceID(of: Self.fixedPartkey) == "DJIMIC3")
        #expect(PartKey.relpath(of: Self.fixedPartkey) == Self.fixedRelpath)
        #expect(PartKey.deviceID(of: "NO NAME/a.wav") == "NO NAME")
        #expect(PartKey.relpath(of: "NO NAME/a.wav") == "a.wav")
        #expect(PartKey.deviceID(of: "DJIMIC3") == nil)
        #expect(PartKey.relpath(of: "DJIMIC3") == nil)
        #expect(PartKey.deviceID(of: "/a.wav") == nil)
        #expect(PartKey.relpath(of: "/a.wav") == "a.wav")
        #expect(PartKey.deviceID(of: "DJIMIC3/") == "DJIMIC3")
        #expect(PartKey.relpath(of: "DJIMIC3/") == nil)
        #expect(PartKey.deviceID(of: "a//b") == "a")
        #expect(PartKey.relpath(of: "a//b") == "/b")
    }

    @Test("F-81 partkey が空文字なら device_id も relpath も nil（TEST-28）")
    func emptyPartkeyHasNeitherPart() {
        #expect(PartKey.deviceID(of: "") == nil)
        #expect(PartKey.relpath(of: "") == nil)
    }

    @Test("F-81 relpath が結合文字や ZWJ で始まっても、最初のスカラーの / で分ける")
    func combiningMarkAfterSlashStillSplits() throws {
        let acute = "DJIMIC3/\u{301}x/TX01_MIC002_20260829_071204_orig.wav"
        // 準備の確かめ: 書記素で探すと最初の "/" を見落とす（これが成り立たなければテストが空振りする）
        let graphemeSlash = try #require(acute.firstIndex(of: "/"))
        try #require(acute[..<graphemeSlash] != "DJIMIC3")
        #expect(Self.scalars(PartKey.deviceID(of: acute)) == Array("DJIMIC3".unicodeScalars))
        #expect(
            Self.scalars(PartKey.relpath(of: acute))
                == Array("\u{301}x/TX01_MIC002_20260829_071204_orig.wav".unicodeScalars))
        let zwj = "DJIMIC3/\u{200D}x/a.wav"
        #expect(Self.scalars(PartKey.deviceID(of: zwj)) == Array("DJIMIC3".unicodeScalars))
        #expect(Self.scalars(PartKey.relpath(of: zwj)) == Array("\u{200D}x/a.wav".unicodeScalars))
    }

    @Test("F-81 make で作った partkey は、relpath が結合文字で始まっても分解で元の 2 つに戻る")
    func makeAndSplitRoundTripWithCombiningMark() throws {
        let relpath = "\u{301}x/TX01_MIC002_20260829_071204_orig.wav"
        let partkey = try PartKey.make(deviceID: "DJIMIC3", relpath: relpath)
        #expect(Self.scalars(partkey) == Array("DJIMIC3/\u{301}x/TX01_MIC002_20260829_071204_orig.wav".unicodeScalars))
        #expect(Self.scalars(PartKey.deviceID(of: partkey)) == Array("DJIMIC3".unicodeScalars))
        #expect(Self.scalars(PartKey.relpath(of: partkey)) == Array(relpath.unicodeScalars))
    }

    @Test("F-81 ASCII の device_id の判定は変わらない")
    func asciiDeviceIDValidityIsUnchanged() {
        #expect(DeviceID.isValid("DJIMIC3"))
        #expect(DeviceID.isValid("NO NAME"))
        #expect(DeviceID.isValid("DJIMIC3 1"))
        #expect(DeviceID.isValid("a.b"))
        #expect(!DeviceID.isValid(".Trashes"))
        #expect(!DeviceID.isValid("."))
        #expect(!DeviceID.isValid(".."))
        #expect(!DeviceID.isValid("a/b"))
        #expect(!DeviceID.isValid("DJI:MIC"))
        #expect(!DeviceID.isValid("a\u{7F}"))
        #expect(!DeviceID.isValid("\t"))
    }

    @Test("F-81 device_id が空文字なら偽（TEST-28）")
    func emptyDeviceIDIsInvalid() {
        #expect(!DeviceID.isValid(""))
    }

    @Test("F-81 「.」の直後に結合文字が来ても「.」で始まる device_id は偽（書記素では「.」始まりに見えない）")
    func dotFollowedByCombiningMarkIsInvalid() throws {
        let id = ".\u{301}DJIMIC3"
        // 準備の確かめ: 書記素の hasPrefix では「.」始まりに見えない
        try #require(!id.hasPrefix("."))
        #expect(!DeviceID.isValid(id))
        #expect(throws: KeyError.invalidDeviceID) { try PartKey.make(deviceID: id, relpath: "a.wav") }
        #expect(throws: KeyError.invalidDeviceID) { try SessionKey.make(deviceID: id, dayStamp: "20260912") }
    }
}
