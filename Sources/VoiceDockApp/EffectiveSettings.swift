// 時刻帯とログに使う、解いた後の設定の値（F-84・issue #119 の G10）。起動（Bootstrap の手順 4・8）とパネルの比べ方が同じ規則を使う。
import Foundation
import VDCore
import VDPipeline

/// 時刻帯とログに使う、解いた後の値。Store・IngestService・AppLog は起動のときの値で作るので、「設定を読み直す」では変わらない
/// （PLAN §8.15 の既知の制限）。起動で使った値を AppContext に残し、今の設定を同じ規則で解いた値と比べてパネルに出す（CR-06）。
struct EffectiveSettings: Equatable, Sendable {
    /// 時刻帯の識別子（`TimeZone.identifier`）
    let timeZoneID: String
    let logLevel: LogLevel
    let unsafeLogContent: Bool

    /// 起動で使った値と、今の設定から解いた値の違い（パネルの「再起動すると反映されます」の 1 行ずつ）
    enum Difference: Equatable, Sendable {
        /// running = 起動で使った識別子、configured = 今の設定の識別子
        case timeZone(running: String, configured: String)
        case logLevel(running: LogLevel, configured: LogLevel)
        /// running = 起動で使った値（今の設定はその逆）
        case unsafeLogContent(running: Bool)
    }

    /// 設定から解く。設定が無い（設定エラー）なら、時刻帯は current（起動の手順 4 の値）、ログは INFO で本文を出さない。
    /// 時刻帯の識別子を解けなければ current（CV-32 が読み込みで弾くので、設定が有効なら解ける）
    static func resolve(_ config: AppConfig?, current: TimeZone = .current) -> EffectiveSettings {
        EffectiveSettings(
            timeZoneID: (config.flatMap { TimeZone(identifier: $0.timeZone) } ?? current).identifier,
            logLevel: config.flatMap { LogLevel(configValue: $0.logging.level) } ?? .info,
            unsafeLogContent: config?.logging.unsafeLogContent ?? false)
    }

    /// 識別子から作った時刻帯（解けなければ current）
    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }

    /// 起動で使った値のまま動いている設定（この順: 時刻帯・ログのレベル・本文を出すか）。設定が無ければ空
    /// （設定エラーの案内に任せる。直してから比べる）
    static func differences(running: EffectiveSettings, config: AppConfig?) -> [Difference] {
        guard let config else { return [] }
        let now = resolve(config, current: running.timeZone)
        var result: [Difference] = []
        if now.timeZoneID != running.timeZoneID {
            result.append(.timeZone(running: running.timeZoneID, configured: now.timeZoneID))
        }
        if now.logLevel != running.logLevel {
            result.append(.logLevel(running: running.logLevel, configured: now.logLevel))
        }
        if now.unsafeLogContent != running.unsafeLogContent {
            result.append(.unsafeLogContent(running: running.unsafeLogContent))
        }
        return result
    }
}
