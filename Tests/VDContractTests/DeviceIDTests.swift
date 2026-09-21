// DeviceID の検査（T-06 §5.4）。
import Foundation
import TestSupport
import Testing

@testable import VDContract

@Suite("DeviceID")
struct DeviceIDTests {
    @Test("実機の名前と空白入りの名前を受ける", arguments: ["DJIMIC3", "NO NAME", "DJI MIC 3", "デバイス"])
    func acceptsTypicalNames(_ id: String) {
        #expect(DeviceID.isValid(id))
    }

    @Test(
        "危険な名前を拒む",
        arguments: ["", "a/b", "a:b", ".hidden", ".", "..", "a\u{0}b", "a\u{1f}b", "a\u{7f}b", "a\nb"])
    func rejectsUnsafeNames(_ id: String) {
        #expect(!DeviceID.isValid(id))
    }
}
