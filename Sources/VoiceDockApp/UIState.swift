// パネルの記憶（PLAN §2.3 / §8.12 の 1・3-④）。UserDefaults を使わない（PR-03）。<HOME>/ui-state.json だけに書く。
import Foundation
import VDContract
import VDCore
import VDDevice

/// パネルの記憶（`<HOME>/ui-state.json`）。キーは `schema`・`loginItemDecided`・`lastConnectedAt`（F-70。nil なら書かない）。
struct UIState: Codable, Equatable, Sendable {
    var schema: Int = UIState.currentSchema
    /// 「ログイン時に起動」をオンにしたか「今はしない」を選んだか（どちらでも true）
    var loginItemDecided: Bool = false
    /// デバイスを最後に観測した時刻（F-70。JSON では epoch ミリ秒の整数。一度も観測していなければ nil で、キーを書かない）
    var lastConnectedAt: Instant? = nil
    static let currentSchema = 1

    private enum CodingKeys: String, CodingKey {
        case schema, loginItemDecided, lastConnectedAt
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(loginItemDecided, forKey: .loginItemDecided)
        try c.encodeIfPresent(lastConnectedAt?.epochMillis, forKey: .lastConnectedAt)
    }
}

extension UIState {
    /// `schema`・`loginItemDecided` は従来どおり必須（欠ければ読めない = 既定）。
    /// `lastConnectedAt` は無くても型が違っても 0 以下でも nil にするだけ（F-70 より前のファイルと、壊れた値で「今はしない」を失わない）。
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        loginItemDecided = try c.decode(Bool.self, forKey: .loginItemDecided)
        let millis = (try? c.decodeIfPresent(Int64.self, forKey: .lastConnectedAt)) ?? nil
        lastConnectedAt = millis.flatMap { $0 > 0 ? Instant(epochMillis: $0) : nil }
    }
}

/// 最終接続（PLAN §8.12 の 1。F-70）。表示する値の決め方と、ui-state.json に書く頻度の抑え方。純関数。
enum LastConnected {
    /// 接続中に書き直す最短の間隔（観測時刻の差。秒）。接続の始まりと切れた後の最後の値はすぐ書く
    static let saveIntervalSeconds = 60

    /// 今デバイスを観測していれば snapshot の時刻。無ければメモリの前回の値、それも無ければ（起動直後）ui-state.json の値
    static func resolve(device: DeviceSnapshot?, carried: Instant?, persisted: Instant?) -> Instant? {
        if let device, !device.devices.isEmpty { return device.completedAt }
        return carried ?? persisted
    }

    /// ui-state.json に書くべき値（書かなくてよければ nil）。
    /// - current: 表示している最終接続
    /// - connected: 今デバイスを観測しているか
    /// - written: この起動で最後に書こうとした値。無ければファイルにある値
    /// 書いた値と違えば書く（時計が戻って小さくなった値も書く）。等しければ書かない
    static func valueToSave(current: Instant?, connected: Bool, written: Instant?) -> Instant? {
        guard let current else { return nil }
        guard let written else { return current }
        guard current != written else { return nil }
        // 接続中は観測のたびに時刻が動くので、差が 60 秒に満たなければ待つ（切れた後の最後の値は待たずに書く）。
        // 差はトラップさせない（桁あふれは「十分に離れている」として書く）
        if connected {
            let (diff, overflow) = current.epochMillis.subtractingReportingOverflow(written.epochMillis)
            if !overflow && diff.magnitude < UInt64(saveIntervalSeconds) * 1000 { return nil }
        }
        return current
    }
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
