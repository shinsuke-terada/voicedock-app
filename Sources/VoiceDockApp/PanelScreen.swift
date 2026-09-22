// パネルの中の画面（PLAN §8.12。主画面はスクロールしない。長い中身は popover の中の別の画面に切り替える。F-65）。
/// パネルの中の画面。popover の外に窓は作らない（D-7）。主画面以外は見出しに「‹ 戻る」を持つ。
enum PanelScreen: String, CaseIterable, Sendable, Equatable {
    /// 状態・要対応（先頭 2 件）・はじめに・保存先・モデル・削除と詳細への行・終了
    case main
    /// 要対応の全件
    case attention
    /// 元音声の削除（3 つのロック・事前確認・長押しの有効化・無効化）
    case deletion
    /// 詳細・診断（診断・LLM の疎通確認・状態の詳細・設定とログ・後追い・版）
    case details
    /// 設定（⚙。ログイン時に起動）
    case settings
}
