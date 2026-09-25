// PyRound が Python の round(x, n) と同じ値を返すこと（PLAN §5.7、T-45）。
import Foundation
import TestSupport
import Testing

@testable import VDCore

@Suite("PyRound")
struct PyRoundTests {
    @Test("golden pyround: Python の round と同じ値（ビット列で一致）")
    func goldenCases() throws {
        let cases = try Golden.cases("pyround")
        #expect(!cases.isEmpty)
        for item in cases {
            let digits = try item.int("digits")
            let outputs = try item.strings("inputs").map { text -> GoldenJSON in
                guard let value = Double(text) else { return .null }
                return .string(PyJSON.formatDouble(PyRound.round(value, digits: digits)))
            }
            GoldenAssert.matchesJSON(.array(outputs), group: "pyround", name: item.name)
        }
    }

    @Test("掛け算の丸めではなく、正確な 2 進値を 10 進で丸める")
    func roundsExactBinaryValue() {
        #expect(PyRound.round(2.675, digits: 2) == 2.67)
        #expect(PyRound.round(0.0005, digits: 3) == 0.001)
        #expect(PyRound.round(0.25, digits: 1) == 0.2)
    }

    @Test("非有限と負の桁数はそのまま返す")
    func passthrough() {
        #expect(PyRound.round(.infinity, digits: 3) == .infinity)
        #expect(PyRound.round(.nan, digits: 3).isNaN)
        #expect(PyRound.round(1.25, digits: -1) == 1.25)
    }
}
