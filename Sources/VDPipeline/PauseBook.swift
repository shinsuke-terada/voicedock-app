// ガードに入った・出たときだけログを出す（毎 tick 出さない。PLAN §5.4）。
import Synchronization
import VDCore

/// ガードの状態とログ。ある理由の「停止中」は「直前に最後まで回った tick でその理由のガードに当たった」。
final class PauseBook: Sendable {
    struct State {
        var previous: Set<PauseReason> = []
        var current: Set<PauseReason> = []
    }

    private let log: AppLog
    private let state = Mutex<State>(State())

    init(log: AppLog) {
        self.log = log
    }

    /// ガードに当たった。前の tick から続いておらず、この tick でもまだ当たっていなければログを出す。
    func trip(_ reason: PauseReason, recordingKey: String? = nil, detail: String? = nil) {
        let entering = state.withLock { s in
            let entering = !s.previous.contains(reason) && !s.current.contains(reason)
            s.current.insert(reason)
            return entering
        }
        guard entering else { return }
        if reason == .diskSpaceLow {
            log.warning(.diskSpaceLow, [(.recordingKey, .of(recordingKey)), (.reason, .of(detail))])
        } else {
            log.warning(.pipelinePaused, [(.reason, .string(reason.rawValue))])
        }
    }

    /// tick を最後まで回したときに呼ぶ。前の tick に当たり、この tick で当たらなかった理由に pipeline_resumed を出す。
    func finishTick() {
        let resumed = state.withLock { s in
            let resumed = s.previous.subtracting(s.current)
            s.previous = s.current
            s.current = []
            return resumed
        }
        for reason in PauseReason.allCases where resumed.contains(reason) {
            log.info(.pipelineResumed, [(.reason, .string(reason.rawValue))])
        }
    }

    /// previous ∪ current を PauseReason.allCases の順で。
    var paused: [PauseReason] {
        let all = state.withLock { $0.previous.union($0.current) }
        return PauseReason.allCases.filter { all.contains($0) }
    }
}
