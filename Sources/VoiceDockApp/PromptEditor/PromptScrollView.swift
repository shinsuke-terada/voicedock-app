// 要約プロンプトの本文の欄を包むスクロールビュー（F-92）。
import AppKit

/// 本文の欄を見えている高さより低くしない（本文が短くても、下の空いた所をクリックしてカーソルを置けるように）。
final class PromptScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let textView = documentView as? NSTextView else { return }
        let height = contentSize.height
        if textView.minSize.height != height {
            textView.minSize = NSSize(width: 0, height: height)
            textView.sizeToFit()
        }
    }
}
