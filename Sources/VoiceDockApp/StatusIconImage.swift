// メニューバーに出す画像（PLAN §8.12 のアイコン ＋ §8.9.8 の trash の常時表示）。
import AppKit

/// メニューバーに出す画像。1 つの NSStatusItem に 2 つの記号を並べる（NSStatusItem を 2 つ作らない。PLAN §8.9.8）。
enum StatusIconImage {
    static let pointSize: CGFloat = 16
    static let height: CGFloat = 18
    static let gap: CGFloat = 3

    /// state の記号 1 つ、showsTrash なら右に trash を並べた 1 枚のテンプレート画像を作る。
    static func make(state: IconState, showsTrash: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard
            let main = NSImage(
                systemSymbolName: state.symbolName, accessibilityDescription: Strings.iconDescription(state)
            )?
            .withSymbolConfiguration(config)
        else { return NSImage() }
        if !showsTrash {
            main.isTemplate = true
            return main
        }
        guard
            let trash = NSImage(
                systemSymbolName: IconState.trashSymbolName, accessibilityDescription: Strings.iconTrashDescription
            )?
            .withSymbolConfiguration(config)
        else {
            main.isTemplate = true
            return main
        }
        let width = main.size.width + gap + trash.size.width
        let composed = NSImage(size: NSSize(width: width, height: height))
        composed.lockFocus()
        main.draw(
            at: NSPoint(x: 0, y: (height - main.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
        trash.draw(
            at: NSPoint(x: main.size.width + gap, y: (height - trash.size.height) / 2), from: .zero,
            operation: .sourceOver, fraction: 1)
        composed.unlockFocus()
        composed.isTemplate = true
        return composed
    }
}
