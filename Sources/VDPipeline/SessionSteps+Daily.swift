// Daily ノート（PLAN §8.6〜§8.8。本体は T-29）。
import VDCore

extension SessionSteps {
    /// ANALYZED / WRITING → SAVED。T-29 までは常に偽。
    func ensureDailyNote(_ key: String, _ t: SessionTranscript) async -> Bool { false }  // T-29 が中身を書く
}
