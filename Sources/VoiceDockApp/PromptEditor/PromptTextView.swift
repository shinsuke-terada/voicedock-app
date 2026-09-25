// 要約プロンプトの本文を編集する欄（F-92）。NSTextView を包み、引用符・ダッシュの自動置換を切る。
import AppKit
import SwiftUI

/// 要約プロンプトの本文を編集する欄（F-92）。SwiftUI の TextEditor はシステムの自動置換（" → “ など）に従い、
/// 書いた本文が LLM に送るものと変わるので使わない。
struct PromptTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PromptNSTextView()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scroll.documentView as? NSTextView else { return }
        // 同じなら書き戻さない（カーソルと Undo の履歴を保つ）
        if !textView.string.unicodeScalars.elementsEqual(text.unicodeScalars) {
            textView.string = text
        }
    }

    /// 編集を binding に写す
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

/// ⌘X・⌘C・⌘V・⌘A・⌘Z・⇧⌘Z を自分で受ける NSTextView（.accessory のアプリにはメニューバーの「編集」が無く、
/// キーの組み合わせがどこにも届かないため。F-92）
final class PromptNSTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
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
        case ("z", true): undoManager?.undo()
        case ("z", false): undoManager?.redo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
