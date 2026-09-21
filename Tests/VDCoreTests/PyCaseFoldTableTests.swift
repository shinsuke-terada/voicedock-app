// casefold の表が生成元（CaseFolding-15.0.0.txt）と一致し、手で編集されていないこと（PLAN §5.7、T-45）。
import CryptoKit
import Foundation
import TestSupport
import Testing

@testable import VDCore

@Suite("PyCaseFoldTable")
struct PyCaseFoldTableTests {
    @Test("生成元の sha256 が記録どおりで、表の見出しにも同じ値がある")
    func sourceHashIsRecorded() throws {
        let source = try Data(contentsOf: PackageRoot.file("tools/unicode/CaseFolding-15.0.0.txt"))
        let digest = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        let recorded = try String(
            contentsOf: PackageRoot.file("tools/unicode/CaseFolding-15.0.0.txt.sha256"), encoding: .utf8)
        #expect(recorded.split(separator: " ").first.map(String.init) == digest)
        let table = try String(contentsOf: PackageRoot.file("Sources/VDCore/PyCaseFoldTable.swift"), encoding: .utf8)
        #expect(table.contains("// source-sha256: \(digest)\n"))
    }

    @Test("C と F の写像の数（1530）と、S と T を含めないこと")
    func entryCountAndStatuses() {
        #expect(PyCaseFoldTable.entryCount == 1530)
        #expect(PyCaseFoldTable.map.count == PyCaseFoldTable.entryCount)
        #expect(PyCaseFoldTable.map[0x1E9E] == [0x73, 0x73])  // ẞ（F）
        #expect(PyCaseFoldTable.map[0x0049] == [0x69])  // I（C。T の 0x0131 ではない）
    }
}
