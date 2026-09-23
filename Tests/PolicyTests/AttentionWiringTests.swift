// 要対応の件数の配線（PLAN §8.11。F-80・issue #119 の R13）: LiveServices.read は DB から数える要対応の件数
// （undeletableSources・rawNoteBlocked）を AttentionInput.countStoredItems の 1 か所で入れる。
// LiveServices は AppContext（Bootstrap が作る本物の依存）を読むのでふるまいのテストに載せられない。数え方は
// DeletionRemainderTests が固定し、ここは read がその関数を呼ぶこと（配線）をトークンで固定する。
import Foundation
import TestSupport
import Testing

@Suite("要対応の件数の配線（F-80）")
struct AttentionWiringTests {
    static let path = "VoiceDockApp/AppServices.swift"

    /// 本体（`{` から対応する `}` まで）の中で `name(` を呼ぶか（`.name(` の形も含む）
    static func calls(_ name: String, in body: ArraySlice<CodeToken>) -> Bool {
        body.indices.contains { index in
            index + 1 < body.endIndex && body[index].kind == .identifier && body[index].text == name
                && body[index + 1].text == "("
        }
    }

    /// `struct LiveServices` から後のトークン（プロトコルの宣言の `func read(` を拾わない）
    static func liveServices(_ tokens: [CodeToken]) -> [CodeToken] {
        guard
            let start = tokens.indices.first(where: {
                $0 + 1 < tokens.count && tokens[$0].text == "struct" && tokens[$0 + 1].text == "LiveServices"
            })
        else { return [] }
        return Array(tokens[start...])
    }

    @Test("F-80 LiveServices.read は DB から数える要対応の件数を AttentionInput.countStoredItems で入れる（数え方を写さない）")
    func readCountsThroughTheSharedFunction() throws {
        let files = try SourceTree.load()
        let services = try #require(files.first { $0.relativePath == Self.path })
        let read = try #require(OrderingPolicy.body(of: "read", in: Self.liveServices(services.tokens)))
        // 本体は read の中だけ（次の func を含まない）
        #expect(!read.contains { $0.text == "requeueManual" })
        #expect(Self.calls("countStoredItems", in: read))
        // 数え方の部品を直に呼ばない（写しを作らない。CR-06）
        for part in ["completedParts", "undeletableStillListed", "rawNoteBlockedSessions"] {
            #expect(!Self.calls(part, in: read), "\(part)")
        }
    }

    @Test("F-80 自己テスト: countStoredItems を呼ばない read・部品を直に呼ぶ read を見分ける")
    func selfTestDetectsMissingOrCopiedWiring() throws {
        let good = SourceFile(
            relativePath: Self.path,
            text: "struct S { func read() { if let ro = open() { attention.countStoredItems(from: ro) } } }")
        let copied = SourceFile(
            relativePath: Self.path,
            text: "struct S { func read() { if let ro = open() { n = try? ro.completedParts(lastDetail: x) } } }")
        let goodBody = try #require(OrderingPolicy.body(of: "read", in: good.tokens))
        let copiedBody = try #require(OrderingPolicy.body(of: "read", in: copied.tokens))
        #expect(Self.calls("countStoredItems", in: goodBody))
        #expect(!Self.calls("countStoredItems", in: copiedBody))
        #expect(Self.calls("completedParts", in: copiedBody))
    }

    @Test("F-80 TEST-28 空のソースには read が無い")
    func emptySourceHasNoRead() {
        let empty = SourceFile(relativePath: Self.path, text: "")
        #expect(OrderingPolicy.body(of: "read", in: empty.tokens) == nil)
    }
}
