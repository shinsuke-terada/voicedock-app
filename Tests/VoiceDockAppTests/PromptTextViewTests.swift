// PromptTextView（要約プロンプトの本文の欄）のテスト（F-92）。プログラムから本文を差し替えたら Undo の履歴を捨てる。
import AppKit
import SwiftUI
import Testing

@testable import VoiceDockApp

@MainActor
@Suite("PromptTextView")
struct PromptTextViewTests {
    /// 欄と同じ設定の NSTextView と、Undo の履歴を持つ Coordinator
    static func make() -> (PromptNSTextView, PromptTextView.Coordinator) {
        let coordinator = PromptTextView.Coordinator(text: .constant(""))
        let textView = PromptNSTextView()
        textView.allowsUndo = true
        textView.delegate = coordinator
        return (textView, coordinator)
    }

    @Test("打鍵の後に本文を差し替えると Undo の履歴を捨てる（短い本文に古い範囲を当てて落ちない）")
    func replaceClearsUndo() {
        let (textView, coordinator) = Self.make()
        PromptTextView.replaceText("0123456789012345678901234567890", in: textView)
        textView.setSelectedRange(NSRange(location: 31, length: 0))
        textView.insertText("abc", replacementRange: NSRange(location: 31, length: 0))
        #expect(textView.undoManager === coordinator.undo)
        #expect(coordinator.undo.canUndo)

        PromptTextView.replaceText("短い", in: textView)
        #expect(!coordinator.undo.canUndo)
        coordinator.undo.undo()
        #expect(textView.string == "短い")
    }

    @Test("空の本文に差し替えても履歴は空（TEST-28）")
    func replaceWithEmpty() {
        let (textView, coordinator) = Self.make()
        PromptTextView.replaceText("", in: textView)
        #expect(textView.string == "")
        #expect(!coordinator.undo.canUndo)
    }

    @Test("窓の無い欄（フォーカスが無い）は ⌘V を受けない")
    func keyEquivalentNeedsFocus() throws {
        let (textView, _) = Self.make()
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        #expect(textView.performKeyEquivalent(with: event) == false)
    }
}
