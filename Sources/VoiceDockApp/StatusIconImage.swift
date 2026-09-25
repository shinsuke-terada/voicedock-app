// メニューバーに出す画像（PLAN §8.12 のアイコン）。削除が有効な印は画像ではなく StatusIconBadge が重ねる（F-91）。
import AppKit

/// メニューバーに出す画像。状態の記号 1 つのテンプレート画像（明暗・強調・減光は AppKit に任せる。F-91）。
enum StatusIconImage {
    static let pointSize: CGFloat = 16

    /// state の記号 1 つのテンプレート画像を作る。showsDeletionBadge は読み上げの説明にだけ効く（赤い点は StatusIconBadge）。
    static func make(state: IconState, showsDeletionBadge: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let description =
            showsDeletionBadge ? Strings.iconDescriptionWithDeletion(state) : Strings.iconDescription(state)
        guard
            let main = NSImage(systemSymbolName: state.symbolName, accessibilityDescription: description)?
                .withSymbolConfiguration(config)
        else { return NSImage() }
        main.isTemplate = true
        return main
    }
}
