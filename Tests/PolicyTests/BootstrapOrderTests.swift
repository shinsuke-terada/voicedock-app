// 起動の順の静的な約束（T-40 §4.4）: Bootstrap.build() でロック 1 の修復口を最初の config.load() より前に挿す（PLAN §6.1）。
// Bootstrap は本番の <HOME> を使うので単体テストで動かせない。コードのトークンの並びで固定する。
import Foundation
import TestSupport
import Testing

@Suite("起動の順（T-40）")
struct BootstrapOrderTests {
    static let path = "VoiceDockApp/Bootstrap.swift"

    /// 違反の説明（無ければ nil）。`func build(` の本体で `setLock1Reconciler(` か `setLock1Reconciler {` が
    /// 最初の `config.load()` より前にあること。
    static func violation(in file: SourceFile) -> String? {
        guard let body = OrderingPolicy.body(of: "build", in: file.tokens) else { return "func build( がありません" }
        var reconciler: Int?
        var load: Int?
        for index in body.indices where index + 1 < body.endIndex {
            let token = body[index]
            guard token.kind == .identifier else { continue }
            let next = body[index + 1].text
            if reconciler == nil && token.text == "setLock1Reconciler" && (next == "(" || next == "{") {
                reconciler = index
            }
            if load == nil && token.text == "load" && next == "(" && index >= body.startIndex + 2
                && body[index - 1].text == "." && body[index - 2].text == "config"
            {
                load = index
            }
        }
        guard let reconciler else { return "setLock1Reconciler がありません" }
        guard let load else { return "config.load() がありません" }
        return reconciler < load ? nil : "setLock1Reconciler が config.load() より後"
    }

    @Test("修復口を最初の config.load() より前に挿す")
    func reconcilerIsInstalledBeforeTheFirstLoad() throws {
        let files = try SourceTree.load()
        let file = try #require(files.first { $0.relativePath == Self.path })
        #expect(Self.violation(in: file) == nil)
    }

    @Test(
        "自己テスト: 順が逆・呼び出しが無い・関数が無いを検出する",
        arguments: [
            (
                "func build() async { await config.setLock1Reconciler { true }\n let a = await config.load() }\n",
                nil as String?
            ),
            (
                "func build() async { let a = await config.load()\n await config.setLock1Reconciler { true } }\n",
                "setLock1Reconciler が config.load() より後"
            ),
            ("func build() async { let a = await config.load() }\n", "setLock1Reconciler がありません"),
            ("func build() async { await config.setLock1Reconciler { true } }\n", "config.load() がありません"),
            ("", "func build( がありません"),
        ])
    func selfTest(_ source: String, _ expected: String?) {
        #expect(Self.violation(in: SourceFile(relativePath: Self.path, text: source)) == expected)
    }

    @Test("自己テスト: コメントの中の setLock1Reconciler は数えない")
    func commentsAreIgnored() {
        let source = "func build() async {\n // config.setLock1Reconciler { }\n let a = await config.load()\n}\n"
        #expect(Self.violation(in: SourceFile(relativePath: Self.path, text: source)) == "setLock1Reconciler がありません")
    }
}
