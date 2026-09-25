// ログイン項目（PLAN §8.12 の 6・§8.11 の DR-12）。SMAppService を触る唯一の場所。
import ServiceManagement
import VDPipeline

/// ログイン項目の読み書きの口（テストで差し替える）。
protocol LoginItemControlling: Sendable {
    func status() -> LoginItemStatus
    /// 成功なら .success、失敗なら表示する文言
    func register() -> LoginItemResult
    func unregister() -> LoginItemResult
    func openSystemSettings()
}

/// register / unregister の結果。`Result` の失敗側は `Error` を要り String は `Error` でないため包み型にする
/// （ConfigUpdateResult と同じ形。ケース名は `Result` と同じ）。
enum LoginItemResult: Equatable, Sendable {
    case success
    /// 表示する文言
    case failure(String)
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

/// register / unregister / システム設定を開く（T-31。PLAN §8.12 の 6）。
extension SystemLoginItem {
    func register() -> LoginItemResult {
        do {
            try SMAppService.mainApp.register()
            return .success
        } catch {
            return .failure(ErrorText.describe(error))
        }
    }

    func unregister() -> LoginItemResult {
        do {
            try SMAppService.mainApp.unregister()
            return .success
        } catch {
            return .failure(ErrorText.describe(error))
        }
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
