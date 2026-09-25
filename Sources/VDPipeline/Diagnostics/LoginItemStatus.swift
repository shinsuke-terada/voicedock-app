// ログイン項目の状態（PLAN §8.11 の DR-12）。値は VoiceDockApp が SMAppService から作って渡す。

/// ログイン項目の状態（PLAN §8.11 の DR-12）。T-32 の Diagnostics が使う。
public enum LoginItemStatus: String, Sendable, Equatable, CaseIterable {
    case enabled, requiresApproval, notRegistered, notFound
}
