// Raw ノートに載る Part の判定（PLAN §8.6・§8.7。T-08）。
import Testing

@testable import VDCore

@Suite("RawNoteMembership")
struct RawNoteMembershipTests {
    @Test("rawNoteMembers でも transcript が読めなければ載らない")
    func membersNeedReadableTranscript() {
        let members: Set<PartStatus> = [
            .transcribed, .rawWriting, .rawSaved, .sourceDeleting, .sourceDeletePending, .completed,
        ]
        var checked = 0
        var trueCount = 0
        for status in PartStatus.allCases {
            for readable in [true, false] {
                let actual = RawNoteMembership.isMember(status: status, transcriptReadable: readable)
                #expect(actual == (members.contains(status) && readable), "\(status) readable=\(readable)")
                checked += 1
                if actual { trueCount += 1 }
            }
        }
        #expect(checked == 24)
        #expect(trueCount == 6)
    }
}
