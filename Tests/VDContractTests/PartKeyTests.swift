// PartKey の検査（T-06 §5.6）。
import Foundation
import TestSupport
import Testing

@testable import VDContract

@Suite("PartKey")
struct PartKeyTests {
    static let device = "DJIMIC3"
    static let relpath = "TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
    static let fixed = "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"

    /// 期待値を書き換えて通すな。規則を変えると、それ以前に保存した録音が永久に削除対象外になる（DEL-01、RK-27）。
    @Test("partkey の固定値")
    func fixedPartkey() throws {
        let key = try PartKey.make(deviceID: Self.device, relpath: Self.relpath)
        #expect(Array(key.utf8) == Array(Self.fixed.utf8))
    }

    @Test("NO NAME でも作れる")
    func acceptsSpaceInDeviceID() throws {
        #expect(try PartKey.make(deviceID: "NO NAME", relpath: "a.wav") == "NO NAME/a.wav")
    }

    @Test("不正な入力を拒む")
    func rejectsInvalidInputs() {
        for device in ["", "a/b", ".hidden", "a:b"] {
            #expect(throws: KeyError.invalidDeviceID) { try PartKey.make(deviceID: device, relpath: Self.relpath) }
        }
        for relpath in ["../escape.wav", "/absolute.wav", ".Trashes/x.wav"] {
            #expect(throws: KeyError.unsafeRelpath) { try PartKey.make(deviceID: Self.device, relpath: relpath) }
        }
    }

    @Test("分解は最初の \"/\"")
    func splitsAtFirstSlash() {
        #expect(PartKey.deviceID(of: "DJIMIC3/a/b.wav") == "DJIMIC3")
        #expect(PartKey.relpath(of: "DJIMIC3/a/b.wav") == "a/b.wav")
        #expect(PartKey.deviceID(of: "noslash") == nil)
        #expect(PartKey.relpath(of: "noslash") == nil)
        #expect(PartKey.deviceID(of: "/a") == nil)
        #expect(PartKey.relpath(of: "/a") == "a")
        #expect(PartKey.deviceID(of: "a/") == "a")
        #expect(PartKey.relpath(of: "a/") == nil)
    }

    @Test("組み立てと分解が往復する")
    func roundTrip() throws {
        let key = try PartKey.make(deviceID: Self.device, relpath: Self.relpath)
        #expect(PartKey.deviceID(of: key) == "DJIMIC3")
        #expect(PartKey.relpath(of: key) == "TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav")
    }
}
