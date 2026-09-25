// 状態の列挙・遷移表・復旧写像の固定（PLAN 付録 A.1〜A.2。T-08）。
import Testing

@testable import VDCore

@Suite("States")
struct StatesTests {
    @Test("Part の状態は付録 A.1 の順")
    func partStatusDeclarationOrder() {
        #expect(
            PartStatus.allCases.map(\.rawValue) == [
                "DISCOVERED", "NORMALIZING", "NORMALIZED", "TRANSCRIBING", "TRANSCRIBED", "RAW_WRITING", "RAW_SAVED",
                "SOURCE_DELETING", "SOURCE_DELETE_PENDING", "COMPLETED", "FAILED", "SKIPPED",
            ])
    }

    @Test("Session の状態は付録 A.1 の順")
    func sessionStatusDeclarationOrder() {
        #expect(
            SessionStatus.allCases.map(\.rawValue) == [
                "OPEN", "READY", "MERGING", "MERGED", "ANALYZING", "ANALYZED", "WRITING", "SAVED", "SOURCE_DELETING",
                "SOURCE_DELETE_PENDING", "CLEANUP", "COMPLETED", "FAILED",
            ])
    }

    @Test("初期状態は DISCOVERED と OPEN")
    func initialStates() {
        #expect(PartStatus.initial == .discovered)
        #expect(SessionStatus.initial == .open)
    }

    @Test("Part の遷移表は 23 本")
    func partTableHas23Edges() {
        let expected: [Edge<PartStatus>] = [
            Edge(.discovered, .normalizing), Edge(.discovered, .skipped),
            Edge(.normalizing, .normalized), Edge(.normalizing, .skipped), Edge(.normalizing, .failed),
            Edge(.normalized, .transcribing), Edge(.normalized, .normalizing),
            Edge(.transcribing, .normalizing), Edge(.transcribing, .transcribed), Edge(.transcribing, .skipped),
            Edge(.transcribing, .failed),
            Edge(.transcribed, .rawWriting),
            Edge(.rawWriting, .rawSaved), Edge(.rawWriting, .failed),
            Edge(.rawSaved, .sourceDeleting), Edge(.rawSaved, .completed),
            Edge(.sourceDeleting, .completed), Edge(.sourceDeleting, .sourceDeletePending),
            Edge(.sourceDeletePending, .sourceDeleting),
            Edge(.completed, .sourceDeleting),
            Edge(.failed, .normalizing), Edge(.failed, .transcribing), Edge(.failed, .rawWriting),
        ]
        #expect(expected.count == 23)
        #expect(TransitionTable.part.count == 23)
        #expect(TransitionTable.part == Set(expected))
    }

    @Test("Session の遷移表は 30 本（voicedock 24 ＋ ★6）")
    func sessionTableHas30Edges() {
        let expected: [Edge<SessionStatus>] = [
            Edge(.open, .open), Edge(.open, .ready), Edge(.ready, .merging),
            Edge(.merging, .merged), Edge(.merging, .completed), Edge(.merging, .failed),
            Edge(.merged, .analyzing), Edge(.analyzing, .analyzed), Edge(.analyzing, .failed),
            Edge(.analyzed, .writing), Edge(.writing, .saved), Edge(.writing, .failed),
            Edge(.saved, .sourceDeleting), Edge(.saved, .cleanup), Edge(.saved, .merging), Edge(.completed, .merging),
            Edge(.sourceDeleting, .cleanup), Edge(.sourceDeleting, .sourceDeletePending),
            Edge(.sourceDeletePending, .sourceDeleting), Edge(.sourceDeletePending, .cleanup),
            Edge(.cleanup, .completed),
            Edge(.failed, .merging), Edge(.failed, .analyzing), Edge(.failed, .writing),
            Edge(.merged, .analyzed),
            Edge(.analyzed, .analyzing), Edge(.writing, .analyzing),
            Edge(.sourceDeleting, .merging), Edge(.sourceDeletePending, .merging), Edge(.cleanup, .merging),
        ]
        #expect(expected.count == 30)
        #expect(TransitionTable.session.count == 30)
        #expect(TransitionTable.session == Set(expected))
    }

    @Test("★ の 6 辺が在る")
    func starEdgesArePresent() {
        let stars: [Edge<SessionStatus>] = [
            Edge(.merged, .analyzed), Edge(.analyzed, .analyzing), Edge(.writing, .analyzing),
            Edge(.sourceDeleting, .merging), Edge(.sourceDeletePending, .merging), Edge(.cleanup, .merging),
        ]
        for edge in stars {
            #expect(TransitionTable.allows(edge, kind: .normal), "\(edge.from)→\(edge.to)")
        }
    }

    @Test("voicedock が表の外で使っていた辺は表に無い")
    func voicedockOutOfTableEdgesAreAbsent() {
        let sessionAbsent: [Edge<SessionStatus>] = [
            Edge(.analyzed, .failed), Edge(.cleanup, .sourceDeleting),
            Edge(.merging, .ready), Edge(.analyzing, .merged), Edge(.writing, .analyzed), Edge(.cleanup, .saved),
        ]
        for edge in sessionAbsent {
            #expect(!TransitionTable.allows(edge, kind: .normal), "\(edge.from)→\(edge.to)")
        }
        let partAbsent: [Edge<PartStatus>] = [
            Edge(.normalizing, .discovered), Edge(.transcribing, .normalized), Edge(.rawWriting, .transcribed),
        ]
        for edge in partAbsent {
            #expect(!TransitionTable.allows(edge, kind: .normal), "\(edge.from)→\(edge.to)")
        }
    }

    @Test("復旧写像は付録 A.1 の順")
    func recoveryMapsInOrder() {
        let part: [Edge<PartStatus>] = [
            Edge(.normalizing, .discovered), Edge(.transcribing, .normalized),
            Edge(.rawWriting, .transcribed), Edge(.sourceDeleting, .sourceDeletePending),
        ]
        let session: [Edge<SessionStatus>] = [
            Edge(.merging, .ready), Edge(.analyzing, .merged), Edge(.writing, .analyzed),
            Edge(.sourceDeleting, .sourceDeletePending), Edge(.cleanup, .saved),
        ]
        #expect(TransitionTable.partRecovery == part)
        #expect(TransitionTable.sessionRecovery == session)
    }

    @Test("復旧専用の辺は recovery でだけ許す")
    func recoveryOnlyEdgesNeedRecoveryKind() {
        let partEdge = Edge(PartStatus.normalizing, .discovered)
        #expect(!TransitionTable.allows(partEdge, kind: .normal))
        #expect(TransitionTable.allows(partEdge, kind: .recovery))
        let sessionEdge = Edge(SessionStatus.cleanup, .saved)
        #expect(!TransitionTable.allows(sessionEdge, kind: .normal))
        #expect(TransitionTable.allows(sessionEdge, kind: .recovery))
    }

    @Test("SOURCE_DELETING→PENDING は両方の kind で許す")
    func sourceDeletingToPendingInBothKinds() {
        let partEdge = Edge(PartStatus.sourceDeleting, .sourceDeletePending)
        #expect(TransitionTable.allows(partEdge, kind: .normal))
        #expect(TransitionTable.allows(partEdge, kind: .recovery))
        let sessionEdge = Edge(SessionStatus.sourceDeleting, .sourceDeletePending)
        #expect(TransitionTable.allows(sessionEdge, kind: .normal))
        #expect(TransitionTable.allows(sessionEdge, kind: .recovery))
    }

    @Test("通常の辺は recovery では許さない")
    func normalEdgeIsNotRecovery() {
        #expect(!TransitionTable.allows(Edge(PartStatus.discovered, .normalizing), kind: .recovery))
    }

    @Test("自己遷移は OPEN→OPEN だけ")
    func openSelfTransitionOnly() {
        #expect(TransitionTable.part.filter { $0.from == $0.to }.isEmpty)
        #expect(TransitionTable.session.filter { $0.from == $0.to } == [Edge(.open, .open)])
    }

    @Test("SKIPPED から出る辺は無い（SM-20）")
    func skippedHasNoOutgoingEdges() {
        #expect(TransitionTable.part.filter { $0.from == .skipped }.isEmpty)
    }

    @Test("FAILED から出る辺の行き先 = retryableFromFailed")
    func failedOutgoingEqualsRetryable() {
        let partOut = Set(TransitionTable.part.filter { $0.from == .failed }.map(\.to))
        #expect(partOut == PartStates.retryableFromFailed)
        let sessionOut = Set(TransitionTable.session.filter { $0.from == .failed }.map(\.to))
        #expect(sessionOut == SessionStates.retryableFromFailed)
    }
}
