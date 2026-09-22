// Timeline の保存（PLAN §8.6。本体は T-29）。
import VDCore
import VDLLM

extension SessionSteps {
    /// Timeline の JSON を保存する。書けなくても失敗にしない。
    func saveTimeline(
        sessionKey: String, summary: String?, partials: [AnalysisResult], chunks: [Chunk],
        transcript: SessionTranscript, fingerprint: String
    ) {}  // T-29 が中身を書く
}
