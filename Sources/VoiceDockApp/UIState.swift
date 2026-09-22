// パネルの記憶（PLAN §2.3 / §8.12 の 3-④）。UserDefaults を使わない（PR-03）。<HOME>/ui-state.json だけに書く。
import Foundation
import VDContract

/// パネルの記憶（`<HOME>/ui-state.json`）。キーは `schema`・`loginItemDecided` の 2 つだけ。
struct UIState: Codable, Equatable, Sendable {
    var schema: Int = UIState.currentSchema
    /// 「ログイン時に起動」をオンにしたか「今はしない」を選んだか（どちらでも true）
    var loginItemDecided: Bool = false
    static let currentSchema = 1
}

/// `UIState` の読み書き。例外を投げない（読めなければ既定、書けなければ false）。
struct UIStateStore: Sendable {
    /// HomeLayout.uiState
    let url: URL

    /// 無い・読めない・JSON でない・schema が 1 でない → 既定（例外を投げない）
    func load() -> UIState {
        guard let data = try? Data(contentsOf: url) else { return UIState() }
        guard let decoded = try? JSONDecoder().decode(UIState.self, from: data) else { return UIState() }
        // 将来の版が書いた値を解釈しない
        guard decoded.schema == UIState.currentSchema else { return UIState() }
        return decoded
    }

    /// AtomicFile.write（0644）。失敗したら false（パネルは「記録できませんでした」と出す）
    func save(_ state: UIState) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard var data = try? encoder.encode(state) else { return false }
        data.append(contentsOf: Array("\n".utf8))
        do {
            try AtomicFile.write(data, to: url, permissions: 0o644)
            return true
        } catch {
            return false
        }
    }
}
