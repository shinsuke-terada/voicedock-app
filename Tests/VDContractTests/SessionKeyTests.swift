// SessionKey の検査（T-06 §5.7）。
import Foundation
import TestSupport
import Testing

@testable import VDContract

@Suite("SessionKey")
struct SessionKeyTests {
    /// 期待値を書き換えて通すな。規則を変えると、それ以前に保存した録音が永久に削除対象外になる（DEL-01、RK-27）。
    @Test("session_key の固定値")
    func fixedSessionKey() throws {
        #expect(try SessionKey.make(deviceID: "DJIMIC3", dayStamp: "20260829") == "DJIMIC3:20260829")
    }

    @Test("溢れた分は #2 から")
    func overflowSuffix() throws {
        #expect(try SessionKey.make(deviceID: "DJIMIC3", dayStamp: "20260829", overflow: 2) == "DJIMIC3:20260829#2")
        #expect(try SessionKey.make(deviceID: "DJIMIC3", dayStamp: "20260829", overflow: 1) == "DJIMIC3:20260829")
    }

    @Test("不正な入力")
    func rejectsInvalid() {
        for device in ["", "a:b", "a/b", ".x"] {
            #expect(throws: KeyError.invalidDeviceID) { try SessionKey.make(deviceID: device, dayStamp: "20260829") }
        }
        for day in ["2026082", "202608290", "2026-08-29", "20260230", "２0260829"] {
            #expect(throws: KeyError.invalidDayStamp) { try SessionKey.make(deviceID: "DJIMIC3", dayStamp: day) }
        }
        for overflow in [0, -1] {
            #expect(throws: KeyError.invalidOverflow) {
                try SessionKey.make(deviceID: "DJIMIC3", dayStamp: "20260829", overflow: overflow)
            }
        }
    }

    @Test("分解は最後の \":\"")
    func parsesComponents() {
        #expect(SessionKey.deviceID(of: "NO NAME:20260829#3") == "NO NAME")
        #expect(SessionKey.dayStamp(of: "NO NAME:20260829#3") == "20260829")
        #expect(SessionKey.overflow(of: "NO NAME:20260829#3") == 3)
        #expect(SessionKey.overflow(of: "DJIMIC3:20260829") == 1)
    }

    @Test(
        "#1・#02・#x は不正",
        arguments: [
            "DJIMIC3:20260829#1", "DJIMIC3:20260829#02", "DJIMIC3:20260829#x", "DJIMIC3:20260829#",
            "DJIMIC3:20260829#-2",
        ])
    func rejectsBadOverflowSuffix(_ key: String) {
        #expect(SessionKey.overflow(of: key) == nil)
    }

    @Test("次の溢れ")
    func nextOverflow() throws {
        #expect(try SessionKey.nextOverflow("DJIMIC3:20260829") == "DJIMIC3:20260829#2")
        #expect(try SessionKey.nextOverflow("DJIMIC3:20260829#2") == "DJIMIC3:20260829#3")
        #expect(try SessionKey.nextOverflow("DJIMIC3:20260829#9") == "DJIMIC3:20260829#10")
        #expect(throws: KeyError.malformedKey) { try SessionKey.nextOverflow("bad") }
        #expect(throws: KeyError.malformedKey) { try SessionKey.nextOverflow("") }
    }
}
