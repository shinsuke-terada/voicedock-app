// 要約プロンプトの本文の欄の NSTextView（F-92）。編集のキーの組み合わせを自分で受ける。
import AppKit

/// ⌘X・⌘C・⌘V・⌘A・⌘Z・⇧⌘Z を自分で受ける NSTextView（.accessory のアプリにはメニューバーの「編集」が無く、
/// キーの組み合わせがどこにも届かないため。F-92）
final class PromptNSTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // 窓は全ビューに配るので、フォーカスが無いときは受けない
        // 変換中（IME の未確定の文字がある間）は NSTextView に任せる
        guard window?.firstResponder === self, !hasMarkedText() else {
            return super.performKeyEquivalent(with: event)
        }
        // Caps Lock などは見ない（⌘・⇧・⌥・⌃ だけで比べる）
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command || flags == [.command, .shift],
            let key = event.charactersIgnoringModifiers?.lowercased()
        else { return super.performKeyEquivalent(with: event) }
        switch (key, flags == .command) {
        case ("x", true): cut(nil)
        case ("c", true): copy(nil)
        case ("v", true): paste(nil)
        case ("a", true): selectAll(nil)
        case ("z", true):
            guard let undo = undoManager, undo.canUndo else { return false }
            undo.undo()
        case ("z", false):
            guard let undo = undoManager, undo.canRedo else { return false }
            undo.redo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
