// Timeline の保存（PLAN §8.5「成功時の書き込み」2・§8.6 Timeline）。書けなくても解析は成功のまま。
import Foundation
import VDContract
import VDCore
import VDLLM
import VDNotes

extension SessionSteps {
    /// analysis/<slug>.timeline.json を書く。書けなくても失敗にしない（config_warning rule=timeline を出す）。
    /// Map-Reduce なら 1 段目の Map 結果とチャンクの組、単一パスなら summary の文を Session の各 Block に（規則は T-27）。
    func saveTimeline(
        sessionKey: String, summary: String?, partials: [AnalysisResult], chunks: [Chunk],
        transcript: SessionTranscript, fingerprint: String
    ) {
        let blocks = Timeline.build(
            partials: partials.map(AnalysisView.init), chunks: chunks.map { (start: $0.startAt, end: $0.endAt) },
            transcript: transcript, summary: summary)
        do {
            try AtomicFile.write(
                Timeline.encode(blocks, fingerprint: fingerprint, zone: zone),
                to: layout.timelineJSON(sessionSlug: KeySlug.of(sessionKey)))
        } catch {
            log.warning(.configWarning, [(.rule, "timeline"), (.message, .string(ErrorText.describe(error)))])
        }
    }
}
