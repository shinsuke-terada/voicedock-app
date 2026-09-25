// 要約プロンプトの編集の窓（F-92。D-7 の例外の 1 つだけの窓）。
import AppKit
import SwiftUI

/// 要約プロンプトの編集の窓（F-92）。StatusItemController が 1 つだけ持ち、閉じても作り直さない。
@MainActor
final class PromptEditorWindowController: NSWindowController, NSWindowDelegate {
    static let initialSize = NSSize(width: 680, height: 560)

    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        let hosting = NSHostingController(rootView: PromptEditorView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = Strings.promptEditorTitle
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(Self.initialSize)
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    /// 前に出して入力を受ける（.accessory のアプリは activate しないと窓がほかのアプリの後ろに残る）
    func show() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.promptEditorDidClose()
    }
}
