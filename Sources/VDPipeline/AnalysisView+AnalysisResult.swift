// 解析結果（VDLLM）を Daily の入力（VDNotes）へ写す。VDNotes は VDLLM を import できないので VDPipeline に置く。
import VDLLM
import VDNotes

extension AnalysisView {
    init(_ r: AnalysisResult) {
        self.init(
            title: r.title, summary: r.summary, keyPoints: r.keyPoints, decisions: r.decisions, ideas: r.ideas,
            tags: r.tags, tasks: r.tasks?.map { (text: $0.text, due: $0.due) })
    }
}
