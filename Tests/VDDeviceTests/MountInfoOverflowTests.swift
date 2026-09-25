// statfs の空き容量の桁あふれ（F-71・#120。C3）。本物の statfs は取らず、値を詰めた構造体から MountInfo を作る。
import Foundation
import TestSupport
import Testing

@testable import VDDevice

@Suite("MountInfo の空き容量（F-71）")
struct MountInfoOverflowTests {
    static func info(bavail: UInt64, bsize: UInt32) -> MountInfo {
        var s = statfs()
        s.f_bavail = bavail
        s.f_bsize = bsize
        return MountInfo(statfs: s)
    }

    @Test("F-71 f_bavail が Int64 に収まらなければ freeBytes は nil（落ちない）")
    func bavailBeyondInt64IsUnobserved() {
        #expect(Self.info(bavail: UInt64.max, bsize: 4096).freeBytes == nil)
        #expect(Self.info(bavail: 9_223_372_036_854_775_808, bsize: 1).freeBytes == nil)
    }

    @Test("F-71 f_bavail が Int64 の最大ちょうどなら読める")
    func bavailAtInt64MaxIsObserved() {
        #expect(Self.info(bavail: 9_223_372_036_854_775_807, bsize: 1).freeBytes == 9_223_372_036_854_775_807)
    }

    @Test("F-71 掛け算があふれたら nil（いままでどおり）")
    func productOverflowIsUnobserved() {
        #expect(Self.info(bavail: 9_223_372_036_854_775_807, bsize: 2).freeBytes == nil)
        #expect(Self.info(bavail: 10, bsize: 4096).freeBytes == 40_960)
    }

    @Test("F-71 空（0 で埋めた）statfs は空き 0・名前は空")
    func zeroedStatfs() {
        let info = Self.info(bavail: 0, bsize: 0)
        #expect(info.freeBytes == 0)
        #expect(info.mountOnName == "")
        #expect(info.fsTypeName == "")
        #expect(info.readOnly == false)
    }
}
