// モデルの後始末の配線（F-83・issue #119。統合で配線。PLAN §8.10・§8.15）: Bootstrap.build は単一起動のロックを取った後・
// Worker と取り込みを始める前に ModelManager.discardStaleImports を呼び、AppDelegate の本番の終了の段は
// ModelDownloader.stopAllKeepingResumeData を呼ぶ。Bootstrap と AppDelegate の本番の部品は本物の <HOME> を使うので
// ふるまいのテストに載せられない。掃除と再開データの中身は VDModels のテスト、段の順は AppDelegateShutdownTests が固定し、
// ここは本番の組み立てがその関数を呼ぶこと（配線）をトークンで固定する。
import Foundation
import TestSupport
import Testing

@Suite("モデルの後始末の配線（F-83）")
struct ModelLifecycleWiringTests {
    static let bootstrapPath = "VoiceDockApp/Bootstrap.swift"
    static let appDelegatePath = "VoiceDockApp/AppDelegate.swift"

    /// 本体の中で `receiver . name (` が最初に現れる位置
    static func firstCall(_ receiver: String, _ name: String, in body: ArraySlice<CodeToken>) -> Int? {
        body.indices.first { index in
            index >= body.startIndex + 2 && index + 1 < body.endIndex && body[index].kind == .identifier
                && body[index].text == name && body[index + 1].text == "(" && body[index - 1].text == "."
                && body[index - 2].text == receiver
        }
    }

    /// Bootstrap.build の違反（無ければ空）: `acquireInstanceLock(` → `models.discardStaleImports(` → `startServices(` の順
    static func bootstrapViolations(in file: SourceFile) -> [String] {
        guard let body = OrderingPolicy.body(of: "build", in: file.tokens) else { return ["func build( がありません"] }
        let lock = OrderingPolicy.firstCall("acquireInstanceLock", in: body)
        let discard = firstCall("models", "discardStaleImports", in: body)
        let start = OrderingPolicy.firstCall("startServices", in: body)
        var out: [String] = []
        if lock == nil { out.append("acquireInstanceLock( がありません") }
        if discard == nil { out.append("models.discardStaleImports( がありません") }
        if start == nil { out.append("startServices( がありません") }
        if let lock, let discard, let start, !(lock < discard && discard < start) {
            out.append("順が acquireInstanceLock → models.discardStaleImports → startServices でない")
        }
        return out
    }

    /// AppDelegate.shutdownParts の違反（無ければ空）: `downloader.stopAllKeepingResumeData(` を呼ぶ
    static func shutdownViolations(in file: SourceFile) -> [String] {
        guard let body = OrderingPolicy.body(of: "shutdownParts", in: file.tokens) else {
            return ["func shutdownParts( がありません"]
        }
        return firstCall("downloader", "stopAllKeepingResumeData", in: body) == nil
            ? ["downloader.stopAllKeepingResumeData( がありません"] : []
    }

    @Test("F-83 起動は単一起動のロックの後・Worker と取り込みを始める前に、取り込みの途中の残り（.custom-import-*.gguf.part）を消す")
    func bootstrapDiscardsStaleImportsBeforeStartingServices() throws {
        let files = try SourceTree.load()
        let file = try #require(files.first { $0.relativePath == Self.bootstrapPath })
        #expect(Self.bootstrapViolations(in: file) == [])
    }

    @Test("F-83 本番の終了の段はダウンロードの再開データを残す（stopAllKeepingResumeData）")
    func shutdownKeepsDownloadResumeData() throws {
        let files = try SourceTree.load()
        let file = try #require(files.first { $0.relativePath == Self.appDelegatePath })
        #expect(Self.shutdownViolations(in: file) == [])
    }

    static let bootstrap = """
        func build() async {
            switch acquireInstanceLock(layout: layout) { default: break }
            let models = ModelManager()
            await models.discardStaleImports()
            ctx.workerTask = await startServices(workerStart: {}, workerRun: {}, ingestStart: {})
        }
        """

    @Test(
        "F-83 自己テスト: Bootstrap の呼び出しの欠落・順の入れ替え・関数が無い（空の入力。TEST-28）を検出する",
        arguments: [
            (bootstrap, [String]()),
            (
                bootstrap.replacingOccurrences(of: "    await models.discardStaleImports()\n", with: ""),
                ["models.discardStaleImports( がありません"]
            ),
            (
                bootstrap.replacingOccurrences(of: "models.discardStaleImports", with: "other.discardStaleImports"),
                ["models.discardStaleImports( がありません"]
            ),
            (
                """
                func build() async {
                    let models = ModelManager()
                    await models.discardStaleImports()
                    switch acquireInstanceLock(layout: layout) { default: break }
                    ctx.workerTask = await startServices(workerStart: {}, workerRun: {}, ingestStart: {})
                }
                """,
                ["順が acquireInstanceLock → models.discardStaleImports → startServices でない"]
            ),
            (
                """
                func build() async {
                    switch acquireInstanceLock(layout: layout) { default: break }
                    ctx.workerTask = await startServices(workerStart: {}, workerRun: {}, ingestStart: {})
                    await models.discardStaleImports()
                }
                """,
                ["順が acquireInstanceLock → models.discardStaleImports → startServices でない"]
            ),
            ("", ["func build( がありません"]),
        ])
    func bootstrapSelfTest(_ source: String, _ expected: [String]) {
        #expect(Self.bootstrapViolations(in: SourceFile(relativePath: Self.bootstrapPath, text: source)) == expected)
    }

    static let shutdown = """
        private static func shutdownParts(_ ctx: AppContext) -> ShutdownParts {
            let downloader = ctx.downloader
            return ShutdownParts(keepDownloadResumeData: { await downloader.stopAllKeepingResumeData() })
        }
        """

    @Test(
        "F-83 自己テスト: 終了の段の stopAllKeepingResumeData の欠落・関数が無い（空の入力。TEST-28）を検出する",
        arguments: [
            (shutdown, [String]()),
            (
                shutdown.replacingOccurrences(of: "await downloader.stopAllKeepingResumeData()", with: ""),
                ["downloader.stopAllKeepingResumeData( がありません"]
            ),
            ("", ["func shutdownParts( がありません"]),
        ])
    func shutdownSelfTest(_ source: String, _ expected: [String]) {
        #expect(Self.shutdownViolations(in: SourceFile(relativePath: Self.appDelegatePath, text: source)) == expected)
    }
}
