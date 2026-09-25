// 終了の要求の配線（PLAN §8.15・F-96）: AppDelegate.requestTerminate は terminate を直に呼ばず、run loop の次の周回で呼ぶ
// （`perform(_:with:afterDelay:)`）。メインアクターの Task の中から直に呼ぶと、`.terminateLater` の返事を待つ入れ子の
// イベントループが後始末の Task を走らせられずに固まった（「初期化して終了」の実機）。AppKit の終了はテストで動かせないので、
// 本体のトークンで固定する。
import Foundation
import TestSupport
import Testing

@Suite("終了の要求の配線（F-96）")
struct TerminateDeferralTests {
    static let path = "VoiceDockApp/AppDelegate.swift"

    /// requestTerminate の違反（無ければ空）: `perform(` と `afterDelay` があり、`terminate(nil)` を直に呼ばない
    static func violations(in file: SourceFile) -> [String] {
        guard let body = OrderingPolicy.body(of: "requestTerminate", in: file.tokens) else {
            return ["func requestTerminate( がありません"]
        }
        var out: [String] = []
        if OrderingPolicy.firstCall("perform", in: body) == nil { out.append("perform( がありません") }
        if !body.contains(where: { $0.kind == .identifier && $0.text == "afterDelay" }) {
            out.append("afterDelay がありません")
        }
        let direct = body.indices.contains { i in
            i + 2 < body.endIndex && body[i].text == "terminate" && body[i + 1].text == "("
                && body[i + 2].text == "nil"
        }
        if direct { out.append("terminate(nil) を直に呼んでいます") }
        return out
    }

    @Test("F-96 requestTerminate は terminate を run loop の次の周回で呼ぶ（Task の中から呼ばれても固まらない）")
    func requestTerminateDefersToTheRunLoop() throws {
        let files = try SourceTree.load()
        let file = try #require(files.first { $0.relativePath == Self.path })
        #expect(Self.violations(in: file) == [])
    }

    static let good = """
        func requestTerminate() {
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        }
        """

    @Test(
        "F-96 自己テスト: 直に呼ぶ・afterDelay が無い・関数が無い（空の入力。TEST-28）を検出する",
        arguments: [
            (good, [String]()),
            (
                "func requestTerminate() {\n    NSApp.terminate(nil)\n}\n",
                ["perform( がありません", "afterDelay がありません", "terminate(nil) を直に呼んでいます"]
            ),
            (
                "func requestTerminate() {\n    NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil)\n}\n",
                ["afterDelay がありません"]
            ),
            ("", ["func requestTerminate( がありません"]),
        ])
    func selfTest(_ source: String, _ expected: [String]) {
        #expect(Self.violations(in: SourceFile(relativePath: Self.path, text: source)) == expected)
    }
}
