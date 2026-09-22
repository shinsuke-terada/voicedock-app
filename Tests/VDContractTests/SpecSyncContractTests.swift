// VDContract の定数と docs/SPEC.md の照合（issue #18。PLAN F-68。T-06 §9・T-07 §9）。
// PolicyTests は VDContract を import できるが、照合は定数の持ち主のテストに置く（PLAN §10.3）。
import TestSupport
import Testing
import VDContract

@Suite("SpecSyncContract")
struct SpecSyncContractTests {
    @Test("名前の正規表現が SPEC S10 の表と逐語で同じ")
    func patternsMatchSpec() throws {
        let patterns = try SpecDocument.load().namePatterns()
        #expect(patterns.count == 3)
        #expect(patterns["RecordingName.filePattern"] == RecordingName.filePattern)
        #expect(patterns["RecordingName.folderPattern"] == RecordingName.folderPattern)
        #expect(patterns["RequestID.pattern"] == RequestID.pattern)
    }

    @Test("理由語が SPEC S8（付録 B.2）の理由語の列と同じ順で同じ")
    func reasonsMatchSpec() throws {
        let words = try SpecDocument.load().reasonWords()
        #expect(!words.isEmpty)
        #expect(IdentityReason.all == words)
    }
}
