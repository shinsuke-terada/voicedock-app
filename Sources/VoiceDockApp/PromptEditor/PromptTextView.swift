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
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        Self.replaceText(text, in: textView)
        let scroll = PromptScrollView()
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
            Self.replaceText(text, in: textView)
        }
    }

    /// プログラムから本文を差し替える（種類の切り替え・既定に戻す）。前の本文への Undo の履歴を捨てる
    /// （残すと ⌘Z が古い範囲を新しい本文に当て、範囲外で落ちるか本文を壊す）
    static func replaceText(_ text: String, in textView: NSTextView) {
        textView.string = text
        textView.undoManager?.removeAllActions()
    }

    /// 編集を binding に写す。Undo の履歴は窓ではなくこの欄だけで持つ
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        let undo = UndoManager()

        init(text: Binding<String>) { self.text = text }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
