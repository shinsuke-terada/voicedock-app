// ModelMemory（モデルを選べるかのメモリの条件）のテスト（T-30 §4.10b）。
import Testing

@testable import VDCore

@Suite("ModelMemory")
struct ModelMemoryTests {
    static let gib: UInt64 = 1_073_741_824

    @Test("minMemoryGB が無ければ足りる")
    func nilRequirementIsAlwaysEnough() {
        #expect(ModelMemory.hasEnough(minMemoryGB: nil, physicalMemoryBytes: 0))
    }

    @Test("ちょうどは足りる")
    func exactIsEnough() {
        #expect(ModelMemory.hasEnough(minMemoryGB: 16, physicalMemoryBytes: 16 * Self.gib))
    }

    @Test("1 バイト足りなければ足りない")
    func oneByteShortIsNotEnough() {
        #expect(!ModelMemory.hasEnough(minMemoryGB: 16, physicalMemoryBytes: 16 * Self.gib - 1))
    }

    @Test("掛け算が溢れる大きさは足りない（trap しない）")
    func overflowingRequirementIsNotEnough() {
        #expect(!ModelMemory.hasEnough(minMemoryGB: Int.max, physicalMemoryBytes: UInt64.max))
    }

    @Test("GB は切り捨て")
    func gbTruncates() {
        #expect(ModelMemory.gb(17 * Self.gib - 1) == 16)
    }
}
