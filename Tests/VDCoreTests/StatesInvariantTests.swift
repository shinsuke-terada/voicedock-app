// 状態の集合と遷移表の不変条件（PLAN §5.1。TEST-08。T-08）。集合の中身を直書きせず、関係だけを検査する。
import Testing

@testable import VDCore

@Suite("States invariants")
struct StatesInvariantTests {
    @Test("deletable ⊂ terminal で差は FAILED と SKIPPED（DEL-02）")
    func deletableIsStrictSubsetOfTerminal() {
        #expect(PartStates.deletable.isStrictSubset(of: PartStates.terminal))
        #expect(PartStates.terminal.subtracting(PartStates.deletable) == [.failed, .skipped])
    }

    @Test("stagingDisposable は terminal から FAILED だけを除く（SM-23）")
    func stagingDisposableExcludesFailed() {
        #expect(PartStates.terminal.subtracting(PartStates.stagingDisposable) == [.failed])
        #expect(PartStates.stagingDisposable.isStrictSubset(of: PartStates.terminal))
    }

    @Test("inboxLeftover は terminal から FAILED だけを除く")
    func inboxLeftoverIsSeparateButEqual() {
        #expect(PartStates.terminal.subtracting(PartStates.inboxLeftover) == [.failed])
        #expect(PartStates.inboxLeftover.isStrictSubset(of: PartStates.terminal))
    }

    @Test("awaitingDeletion = deletable − COMPLETED")
    func awaitingDeletionIsDeletableMinusCompleted() {
        #expect(PartStates.deletable.subtracting(PartStates.awaitingDeletion) == [.completed])
        #expect(PartStates.awaitingDeletion.isStrictSubset(of: PartStates.deletable))
    }

    @Test("進行中の全状態に復旧先がある（SM-07）")
    func inProgressEqualsRecoveryDomain() {
        #expect(Set(TransitionTable.partRecovery.map(\.from)) == PartStates.inProgress)
        #expect(Set(TransitionTable.sessionRecovery.map(\.from)) == SessionStates.inProgress)
    }

    @Test("復旧写像の遷移元は重複しない")
    func recoveryDomainHasNoDuplicates() {
        let partFrom = TransitionTable.partRecovery.map(\.from)
        #expect(partFrom.count == Set(partFrom).count)
        let sessionFrom = TransitionTable.sessionRecovery.map(\.from)
        #expect(sessionFrom.count == Set(sessionFrom).count)
    }

    @Test("FAILED に入る辺の遷移元 = FAILED から出る辺の行き先 = retryableFromFailed")
    func retryableFromFailedIsSymmetric() {
        let partInto = Set(TransitionTable.part.filter { $0.to == .failed && $0.from != .failed }.map(\.from))
        let partOut = Set(TransitionTable.part.filter { $0.from == .failed }.map(\.to))
        #expect(partInto == partOut)
        #expect(partOut == PartStates.retryableFromFailed)
        let sessionInto = Set(TransitionTable.session.filter { $0.to == .failed && $0.from != .failed }.map(\.from))
        let sessionOut = Set(TransitionTable.session.filter { $0.from == .failed }.map(\.to))
        #expect(sessionInto == sessionOut)
        #expect(sessionOut == SessionStates.retryableFromFailed)
    }

    @Test("名前が ING で終わる状態は進行中か SOURCE_DELETE_PENDING（SM-10）")
    func ingStatesAreInProgressOrPending() {
        for status in PartStatus.allCases where status.rawValue.hasSuffix("ING") {
            #expect(PartStates.inProgress.contains(status) || status == .sourceDeletePending, "\(status)")
        }
        for status in SessionStatus.allCases where status.rawValue.hasSuffix("ING") {
            #expect(SessionStates.inProgress.contains(status) || status == .sourceDeletePending, "\(status)")
        }
    }

    @Test("進行中は終端ではない（SOURCE_DELETING だけは終端にも含む）")
    func inProgressIsNotTerminalExceptSourceDeleting() {
        #expect(PartStates.inProgress.intersection(PartStates.terminal.subtracting([.sourceDeleting])).isEmpty)
        #expect(PartStates.terminal.contains(.sourceDeleting))
    }

    @Test("復旧の行き先から通常の辺で再開できる")
    func recoveryTargetsCanResume() {
        for edge in TransitionTable.partRecovery {
            #expect(TransitionTable.part.contains { $0.from == edge.to }, "\(edge.to)")
            #expect(!PartStates.inProgress.contains(edge.to), "\(edge.to)")
        }
        for edge in TransitionTable.sessionRecovery {
            #expect(TransitionTable.session.contains { $0.from == edge.to }, "\(edge.to)")
            #expect(!SessionStates.inProgress.contains(edge.to), "\(edge.to)")
        }
    }

    @Test("初期状態から全状態へ到達できる")
    func allStatesReachable() {
        #expect(Self.reachable(from: PartStatus.initial, in: TransitionTable.part) == Set(PartStatus.allCases))
        #expect(Self.reachable(from: SessionStatus.initial, in: TransitionTable.session) == Set(SessionStatus.allCases))
    }

    @Test("retry_count を戻す状態は工程通過の状態")
    func retryResetAreStagePasses() {
        #expect(PartStates.retryReset.count == 3)
        #expect(SessionStates.retryReset.count == 3)
        for status in PartStates.retryReset {
            #expect(!status.rawValue.hasSuffix("ING"), "\(status)")
        }
        for status in SessionStates.retryReset {
            #expect(!status.rawValue.hasSuffix("ING"), "\(status)")
        }
    }

    @Test("processable = mergeable ∪ analyzable ∪ writable")
    func processableIsUnion() {
        #expect(
            SessionStates.processable
                == SessionStates.mergeable.union(SessionStates.analyzable).union(SessionStates.writable))
    }

    @Test("cleanupFrom ⊂ deleteEvaluated")
    func cleanupFromIsInDeleteEvaluated() {
        #expect(SessionStates.cleanupFrom.isStrictSubset(of: SessionStates.deleteEvaluated))
    }

    @Test("savedOrBeyond ⊂ mergedOrBeyond")
    func savedOrBeyondInMergedOrBeyond() {
        #expect(SessionStates.savedOrBeyond.isStrictSubset(of: SessionStates.mergedOrBeyond))
    }

    @Test("rawSavedOrBeyond ⊂ transcribedOrBeyond ⊂ normalizedOrBeyond")
    func beyondSetsAreNested() {
        #expect(PartStates.rawSavedOrBeyond.isStrictSubset(of: PartStates.transcribedOrBeyond))
        #expect(PartStates.transcribedOrBeyond.isStrictSubset(of: PartStates.normalizedOrBeyond))
    }

    @Test("rawSavedOrBeyond = deletable")
    func rawSavedOrBeyondEqualsDeletable() {
        #expect(PartStates.rawSavedOrBeyond == PartStates.deletable)
    }

    @Test("各工程の入口は進行中の状態を含む（SM-08）")
    func stageEntrancesContainTheirInProgress() {
        #expect(PartStates.normalizable.contains(.normalizing))
        #expect(PartStates.transcribable.contains(.transcribing))
        #expect(PartStates.rawWritable.contains(.rawWriting))
        #expect(SessionStates.mergeable.contains(.merging))
        #expect(SessionStates.analyzable.contains(.analyzing))
        #expect(SessionStates.writable.contains(.writing))
    }

    @Test("再オープン元は削除段を含む（X-31）")
    func reopenableHasDeletionStages() {
        #expect(SessionStates.reopenable == [.saved, .sourceDeleting, .sourceDeletePending, .cleanup, .completed])
        for status in SessionStates.reopenable {
            #expect(TransitionTable.session.contains(Edge(status, .merging)), "\(status)")
        }
    }

    @Test("deletable と benign は同値だが別定数")
    func skipReasonsAreSeparateConstants() {
        #expect(SkipReasons.deletable == SkipReasons.benign)
        #expect(SkipReasons.deletable == [.duplicateContent, .noSpeechDetected])
        #expect(SkipReasons.benign == [.duplicateContent, .noSpeechDetected])
    }

    @Test("根拠 B の理由は skipReasonWord を持つ")
    func deletableSkipReasonsAreSkipCodes() {
        #expect(!SkipReasons.deletable.isEmpty)
        for code in SkipReasons.deletable {
            #expect(code.skipReasonWord != nil, "\(code)")
        }
    }

    /// normal 表を幅優先で辿った到達集合。
    private static func reachable<S>(from start: S, in table: Set<Edge<S>>) -> Set<S> {
        var seen: Set<S> = [start]
        var queue: [S] = [start]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            for edge in table where edge.from == current && !seen.contains(edge.to) {
                seen.insert(edge.to)
                queue.append(edge.to)
            }
        }
        return seen
    }
}
