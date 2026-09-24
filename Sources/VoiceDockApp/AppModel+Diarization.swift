// 話者分離のトグル（PLAN §8.12 の 6。F-89）。
import Foundation

extension AppModel {
    /// 設定に書く。違反なら書かずに modelError に出す（selectLLM と同じ）。
    func setDiarization(_ on: Bool) async {
        let r = await services.updateConfig { $0.transcription.diarization.enabled = on }
        switch r {
        case .failure(let v): modelError = Strings.configRejected(v)
        case .success: modelError = nil
        }
        await refresh()
    }
}
