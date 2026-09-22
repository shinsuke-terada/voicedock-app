// 複製の手順の静的な約束（T-40 §4.3.3・PLAN §8.9.3 の 6）: installReaper の本体が fsync → 署名検証 → chmod → rename の順で、
// 書き込みの open( に O_NOFOLLOW があること。fsync を消す・順を入れ替える壊し方はふるまいのテストで観測できないため、トークンで固定する。
import Foundation
import TestSupport
import Testing

@Suite("複製の手順（T-40）")
struct ReaperInstallOrderTests {
    static let path = "VDPipeline/DeletionEnabler.swift"
    static let function = "installReaper"

    /// 本体の中で、`name(` が最初に現れる位置（`receiver` を渡したら `receiver . name (` の形だけ）
    static func firstCall(_ name: String, receiver: String? = nil, in body: ArraySlice<CodeToken>) -> Int? {
        for index in body.indices where index + 1 < body.endIndex {
            guard body[index].kind == .identifier, body[index].text == name, body[index + 1].text == "(" else {
                continue
            }
            if let receiver {
                guard index >= body.startIndex + 2, body[index - 1].text == ".", body[index - 2].text == receiver
                else { continue }
            }
            return index
        }
        return nil
    }

    /// `open(` の引数のトークン（釣り合う `)` まで）の一覧
    static func openArguments(in body: ArraySlice<CodeToken>) -> [[String]] {
        var out: [[String]] = []
        for index in body.indices where index + 1 < body.endIndex {
            guard body[index].kind == .identifier, body[index].text == "open", body[index + 1].text == "(" else {
                continue
            }
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
            out.append(args)
        }
        return out
    }

    /// 違反の説明（無ければ空）
    static func violations(in file: SourceFile) -> [String] {
        guard let body = OrderingPolicy.body(of: function, in: file.tokens) else {
            return ["func installReaper( がありません"]
        }
        var out: [String] = []
        let steps: [(String, Int?)] = [
            ("fsync", firstCall("fsync", in: body)),
            ("verifier.verify", firstCall("verify", receiver: "verifier", in: body)),
            ("chmod", firstCall("chmod", in: body)),
            ("rename", firstCall("rename", in: body)),
        ]
        for (name, index) in steps where index == nil { out.append(name + "( がありません") }
        let found = steps.compactMap(\.1)
        if found.count == steps.count && found != found.sorted() {
            out.append("順が fsync → verifier.verify → chmod → rename でない")
        }
        let writes = openArguments(in: body).filter { $0.contains("O_WRONLY") || $0.contains("O_CREAT") }
        if writes.isEmpty { out.append("書き込みの open( がありません") }
        if writes.contains(where: { !$0.contains("O_NOFOLLOW") }) { out.append("書き込みの open( に O_NOFOLLOW が無い") }
        return out
    }

    @Test("installReaper は fsync → 署名検証 → chmod → rename の順で、書き込みの open( に O_NOFOLLOW がある")
    func installReaperKeepsTheOrder() throws {
        let file = try #require(try SourceTree.load().first { $0.relativePath == Self.path })
        #expect(Self.violations(in: file) == [])
    }

    static let good = """
        func installReaper() {
            let out = open(p(tmp), O_WRONLY | O_CREAT | O_NOFOLLOW, 0o700)
            _ = fsync(out)
            guard verifier.verify(url: tmp) else { return }
            _ = chmod(p(tmp), 0o755)
            _ = rename(p(tmp), p(dst))
            let dir = open(p(bin), O_RDONLY | O_DIRECTORY)
        }
        """

    static let swappedChmodAndRename = """
        func installReaper() {
            let out = open(p(tmp), O_WRONLY | O_CREAT | O_NOFOLLOW, 0o700)
            _ = fsync(out)
            guard verifier.verify(url: tmp) else { return }
            _ = rename(p(tmp), p(dst))
            _ = chmod(p(dst), 0o755)
        }
        """

    @Test(
        "自己テスト: 順の入れ替え・欠落・O_NOFOLLOW の欠落を検出する",
        arguments: [
            (good, [String]()),
            (
                good.replacingOccurrences(of: "_ = fsync(out)\n", with: ""),
                ["fsync( がありません"]
            ),
            (swappedChmodAndRename, ["順が fsync → verifier.verify → chmod → rename でない"]),
            (
                good.replacingOccurrences(of: "O_WRONLY | O_CREAT | O_NOFOLLOW", with: "O_WRONLY | O_CREAT"),
                ["書き込みの open( に O_NOFOLLOW が無い"]
            ),
            ("", ["func installReaper( がありません"]),
        ])
    func selfTest(_ source: String, _ expected: [String]) {
        #expect(Self.violations(in: SourceFile(relativePath: Self.path, text: source)) == expected)
    }
}
