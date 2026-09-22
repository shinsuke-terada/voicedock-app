// Part の工程: Raw ノートの書き込み（PLAN §8.6〜§8.8。本体は T-29）。
import VDStore

extension PartSteps {
    // T-29 が中身を書く（PLAN §8.6〜§8.8）。
    func ensureRawNote(_ row: RecordingRow) async -> Bool { false }
}
