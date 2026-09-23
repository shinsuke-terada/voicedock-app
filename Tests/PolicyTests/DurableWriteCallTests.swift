// 書き出し（F_FULLFSYNC）の呼び出しの静的な約束（F-83。PLAN §8.7・§8.10。issue #119 の F9・F10）:
// NoteWriter.write は AtomicFile.write に `fullSync: true` を渡す。ModelDownloader.download は照合した .part を
// ModelFileSync.syncFile してから rename し、後に syncParent する。ModelImporter は copyHashing で AtomicFile.fullFsync し、
// importGGUF で rename の後に syncParent する。F_FULLFSYNC を fsync に戻す・消す壊し方はふるまいのテストで観測できないため、トークンで固定する。
import Foundation
import TestSupport
import Testing

@Suite("書き出しの呼び出し（F-83）")
struct DurableWriteCallTests {
    struct Rule {
        let path: String
        let function: String
        /// `受け手.名前(` を、この順に全部含むこと
        let calls: [(receiver: String, name: String)]
        /// 最初の呼び出しの引数に `fullSync: true` を含むこと
        let fullSyncTrue: Bool
    }

    static let rules: [Rule] = [
        Rule(
            path: "VDNotes/NoteWriter.swift", function: "write", calls: [("AtomicFile", "write")], fullSyncTrue: true),
        Rule(
            path: "VDModels/ModelDownloader.swift", function: "download",
            calls: [("ModelFileSync", "syncFile"), ("Darwin", "rename"), ("ModelFileSync", "syncParent")],
            fullSyncTrue: false),
        Rule(
            path: "VDModels/ModelImporter.swift", function: "copyHashing", calls: [("AtomicFile", "fullFsync")],
            fullSyncTrue: false),
        Rule(
            path: "VDModels/ModelImporter.swift", function: "importGGUF",
            calls: [("Darwin", "rename"), ("ModelFileSync", "syncParent")], fullSyncTrue: false),
    ]

    /// 本体の中で `receiver . name (` が最初に現れる位置
    static func firstCall(_ receiver: String, _ name: String, in body: ArraySlice<CodeToken>) -> Int? {
        body.indices.first { index in
            index >= body.startIndex + 2 && index + 1 < body.endIndex && body[index].kind == .identifier
                && body[index].text == name && body[index + 1].text == "(" && body[index - 1].text == "."
                && body[index - 2].text == receiver
        }
    }

    /// index の `(` から釣り合う `)` までの引数のトークン
    static func arguments(at index: Int, in body: ArraySlice<CodeToken>) -> [String] {
        var depth = 0
        var args: [String] = []
        for j in (index + 1)..<body.endIndex {
            let t = body[j].text
            if t == "(" { depth += 1 }
            if t == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            args.append(t)
        }
        return args
    }

    /// 違反の説明（無ければ空）
    static func violations(_ rule: Rule, in file: SourceFile) -> [String] {
        guard let body = OrderingPolicy.body(of: rule.function, in: file.tokens) else {
            return ["func \(rule.function)( がありません"]
        }
        var out: [String] = []
        let found = rule.calls.map { firstCall($0.receiver, $0.name, in: body) }
        for (call, index) in zip(rule.calls, found) where index == nil {
            out.append("\(call.receiver).\(call.name)( がありません")
        }
        let present = found.compactMap { $0 }
        if present.count == rule.calls.count && present != present.sorted() {
            out.append("順が " + rule.calls.map { "\($0.receiver).\($0.name)" }.joined(separator: " → ") + " でない")
        }
        if rule.fullSyncTrue, let first = present.first {
            let args = arguments(at: first + 1, in: body)
            let hasFullSyncTrue = args.indices.contains { i in
                i + 2 < args.count && args[i] == "fullSync" && args[i + 1] == ":" && args[i + 2] == "true"
            }
            if !hasFullSyncTrue { out.append("fullSync: true を渡していない") }
        }
        return out
    }

    @Test("F-83 ノートは fullSync: true、モデルは照合した .part を書き出してから rename し、親も書き出す")
    func durableWritesAreCalled() throws {
        let files = try SourceTree.load()
        for rule in Self.rules {
            let file = try #require(files.first { $0.relativePath == rule.path }, "\(rule.path) がありません")
            #expect(Self.violations(rule, in: file) == [], "\(rule.path) の \(rule.function)")
        }
    }

    static let noteWriter = """
        func write(_ content: String, to url: URL) throws {
            try AtomicFile.write(data, to: url, permissions: 0o644, verifyReadBack: true, fullSync: true)
        }
        """

    static let downloader = """
        func download() {
            guard ModelFileSync.syncFile(part) == nil else { return }
            guard Darwin.rename(a, b) == 0 else { return }
            ModelFileSync.syncParent(of: final)
        }
        """

    @Test(
        "F-83 自己テスト: fullSync の欠落・偽、呼び出しの欠落・順の入れ替え、関数が無い（空の入力。TEST-28）を検出する",
        arguments: [
            (0, noteWriter, [String]()),
            (0, noteWriter.replacingOccurrences(of: ", fullSync: true", with: ""), ["fullSync: true を渡していない"]),
            (
                0, noteWriter.replacingOccurrences(of: "fullSync: true", with: "fullSync: false"),
                ["fullSync: true を渡していない"]
            ),
            (1, downloader, [String]()),
            (
                1,
                downloader.replacingOccurrences(
                    of: "guard ModelFileSync.syncFile(part) == nil else { return }\n", with: ""),
                ["ModelFileSync.syncFile( がありません"]
            ),
            (
                1,
                """
                func download() {
                    guard Darwin.rename(a, b) == 0 else { return }
                    guard ModelFileSync.syncFile(part) == nil else { return }
                    ModelFileSync.syncParent(of: final)
                }
                """,
                ["順が ModelFileSync.syncFile → Darwin.rename → ModelFileSync.syncParent でない"]
            ),
            (0, "", ["func write( がありません"]),
        ])
    func selfTest(_ rule: Int, _ source: String, _ expected: [String]) {
        let r = Self.rules[rule]
        #expect(Self.violations(r, in: SourceFile(relativePath: r.path, text: source)) == expected)
    }
}
