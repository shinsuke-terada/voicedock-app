// パネルの「元音声の削除」に出す値と文言（PLAN §8.9.8）。逐語はここだけ（CR-06）。
import Foundation

public enum DeletionStrings {
    /// 有効化の事前確認（PLAN §8.9.8 の 1）
    public static let confirmVerified = "1 日以上の運用で Raw ノートが正しく作られていることを確かめましたか"
    public static let confirmIrreversible = "消した録音は戻りません"
    /// PLAN §8.9.8 の 2。完全一致でしか通さない
    public static let confirmationWord = "ENABLE"
    /// PLAN §8.9.8 の 5
    public static let reinsertNotice = "読み書きできるようになるのはデバイスを挿し直した後です"
    /// PLAN §8.9.3 の 5 / §8.9.8 のロック 2-A の行
    public static let reaperUpdateNotice = "削除モジュールの更新が必要です"
}

/// パネルとメニューバーが読む値（T-30 の AppModel が持つ）。
public struct DeletionPanelState: Equatable, Sendable {
    /// PLAN §8.9.8 の 3 行（LockDisplay.lines のまま）
    public let lines: [String]
    /// メニューバーのアイコンの横に `trash` を常に出すか
    public let showsTrash: Bool
    /// 3 行の下に足す注意書き（この順）
    public let notices: [String]
    /// 根拠 B が有効か
    public let skippedEnabled: Bool
    /// 「無音・重複も消す」を出すか
    public let showsSkippedToggle: Bool

    public init(display: LockDisplay, deleteSkippedSource: Bool) {
        // 1.
        lines = display.lines
        // 2. 片方だけ有効な中途の状態でも出す（消える可能性がある間はいつでも見える）。readiness では判定しない
        let trash = display.appEnabled || display.confState == .enabled
        showsTrash = trash
        // 3.（この順。当てはまるものだけ）
        var notices: [String] = []
        if case .versionMismatch = display.reaper {
            notices.append(DeletionStrings.reaperUpdateNotice)
        }
        let notWritable = (display.devices ?? []).contains { $0.writability == .readOnly || $0.writability == .unknown }
        if trash && notWritable {
            notices.append(DeletionStrings.reinsertNotice)
        }
        self.notices = notices
        // 4.
        skippedEnabled = deleteSkippedSource
        // 5. CV-43 と同じ条件
        showsSkippedToggle = display.appEnabled
    }
}
