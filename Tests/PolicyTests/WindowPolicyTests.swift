// 窓の数の静的な約束（D-7・F-92）。メニューバーのパネルのほかに作ってよい窓は要約プロンプトの編集の窓 1 つだけ。
import Foundation
import TestSupport
import Testing

@Suite("WindowPolicy")
struct WindowPolicyTests {
    /// 窓を作る型・シーン（NSAlert・NSOpenPanel はモーダルなので対象外。NSWindowDelegate も窓を作らない）
    static let windowMakers: Set<String> = [
        "NSWindow", "NSWindowController", "NSPanel", "WindowGroup", "Window", "DocumentGroup", "Settings",
        "UtilityWindow",
    ]
    static let promptEditor = "VoiceDockApp/PromptEditor/PromptEditorWindowController.swift"

    static func identifiers(_ file: SourceFile) -> Set<String> {
        Set(file.tokens.filter { $0.kind == .identifier }.map(\.text))
    }

    @Test("窓を作ってよいのは PromptEditorWindowController.swift だけ（D-7 の例外は 1 つ。F-92）")
    func onlyThePromptEditorMakesAWindow() throws {
        let files = try SourceTree.load()
        // 陽性対照: 例外のファイルは NSWindow と NSWindowController を持つ（語の取り出しが効いている）
        let editor = try #require(files.first { $0.relativePath == Self.promptEditor })
        #expect(Self.identifiers(editor).isSuperset(of: ["NSWindow", "NSWindowController"]))
        let offenders = files.filter { $0.relativePath != Self.promptEditor }
            .compactMap { file -> String? in
                let found = Self.identifiers(file).intersection(Self.windowMakers)
                return found.isEmpty ? nil : "\(file.relativePath): \(found.sorted())"
            }
        #expect(offenders == [])
    }

    @Test("窓を作るのは StatusItemController の 1 か所だけ（1 つを使い回す）")
    func editorIsCreatedOnce() throws {
        let files = try SourceTree.load()
        let creators = files.filter { Self.identifiers($0).contains("PromptEditorWindowController") }
            .map(\.relativePath).sorted()
        #expect(creators == [Self.promptEditor, "VoiceDockApp/StatusItemController.swift"])
    }
}
