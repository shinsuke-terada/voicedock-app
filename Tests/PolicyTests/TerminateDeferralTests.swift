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

    /// applicationShouldTerminate の違反（無ければ空）: 返事は replyOnMainRunLoop から返し（直に reply を呼ばない）、
    /// 後始末はメインアクターの Task で回さない。replyOnMainRunLoop は CFRunLoopPerformBlock で積む（レビューの #5）
    static func replyViolations(in file: SourceFile) -> [String] {
        guard let should = OrderingPolicy.body(of: "applicationShouldTerminate", in: file.tokens) else {
            return ["func applicationShouldTerminate( がありません"]
        }
        var out: [String] = []
        if OrderingPolicy.firstCall("replyOnMainRunLoop", in: should) == nil {
            out.append("replyOnMainRunLoop( がありません")
        }
        if should.contains(where: { $0.kind == .identifier && $0.text == "reply" }) {
            out.append("reply を直に呼んでいます")
        }
        if should.contains(where: { $0.kind == .identifier && $0.text == "MainActor" }) {
            out.append("後始末をメインアクターで回しています")
        }
        guard let reply = OrderingPolicy.body(of: "replyOnMainRunLoop", in: file.tokens) else {
            return out + ["func replyOnMainRunLoop( がありません"]
        }
        if OrderingPolicy.firstCall("CFRunLoopPerformBlock", in: reply) == nil {
            out.append("CFRunLoopPerformBlock( がありません")
        }
        return out
    }

    @Test("F-96 終了の返事は main run loop から返す（terminate がメインアクターの Task の中から呼ばれても固まらない）")
    func terminateReplyUsesTheMainRunLoop() throws {
        let files = try SourceTree.load()
        let file = try #require(files.first { $0.relativePath == Self.path })
        #expect(Self.replyViolations(in: file) == [])
    }

    static let goodReply = """
        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            Task.detached { _ = await Self.shutDown(within: timeout, steps); Self.replyOnMainRunLoop() }
            return .terminateLater
        }
        nonisolated static func replyOnMainRunLoop() {
            CFRunLoopPerformBlock(CFRunLoopGetMain(), mode) {
                MainActor.assumeIsolated { NSApp.reply(toApplicationShouldTerminate: true) }
            }
        }
        """

    @Test(
        "F-96 自己テスト: 直の reply・メインアクターの Task・run loop に積まない・関数が無い（空の入力。TEST-28）を検出する",
        arguments: [
            (goodReply, [String]()),
            (
                goodReply.replacingOccurrences(
                    of: "Self.replyOnMainRunLoop()", with: "NSApp.reply(toApplicationShouldTerminate: true)"),
                ["replyOnMainRunLoop( がありません", "reply を直に呼んでいます"]
            ),
            (
                goodReply.replacingOccurrences(of: "Task.detached {", with: "Task { @MainActor in"),
                ["後始末をメインアクターで回しています"]
            ),
            (
                goodReply.replacingOccurrences(
                    of: "CFRunLoopPerformBlock(CFRunLoopGetMain(), mode)", with: "DispatchQueue.main.async"),
                ["CFRunLoopPerformBlock( がありません"]
            ),
            ("", ["func applicationShouldTerminate( がありません"]),
        ])
    func replySelfTest(_ source: String, _ expected: [String]) {
        #expect(Self.replyViolations(in: SourceFile(relativePath: Self.path, text: source)) == expected)
    }
}
