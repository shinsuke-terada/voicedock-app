// ログイン項目（PLAN §8.12 の 6・§8.11 の DR-12）。SMAppService を触る唯一の場所。
// このチケットは status() だけを作る。register / unregister / openSystemSettingsLoginItems は T-31 が足す。
import ServiceManagement
import VDPipeline

/// ログイン項目の読み書きの口（テストで差し替える）。
protocol LoginItemControlling: Sendable {
    func status() -> LoginItemStatus
}

/// 本番の LoginItemControlling（SMAppService.mainApp）。
struct SystemLoginItem: LoginItemControlling {
    func status() -> LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }
}
