// 削除の必要十分条件の式の形そのものを固定する（PLAN §8.9.1・TEST-30。T-36）。
// 振る舞いでは落とせない冗長な項（番犬）が式に在ること、|| が共通項の内側にあることを、ソースのトークンで確かめる。
// 式を変えるなら PLAN §8.9.1 を先に直し、ここの期待値を同じ PR で直す。
import Foundation
import TestSupport
import Testing

@Suite("DeletionFormula")
struct DeletionFormulaTests {
    static let path = "VDPipeline/DeletionPolicy.swift"

    /// 期待する本体（PLAN §8.9.1 の式を Swift に写したもの）。トークンを並べ、識別子・数値が隣り合う所だけ空白 1 つを挟んだ形。
    /// 振る舞いでは落とせない項と、その理由:
    /// - canDeleteSource の `&&(…||…)`: 根拠 B 単独のテストは `||` が外に出ても通る（共通項を迂回した形でも根拠 B の正の対照は真のまま）
    /// - 同 `c.part.sourcePath!=nil` と `c.part.sourcePath?.isEmpty==false`: preIdentityCheck が同じ値を先に偽にする
    /// - textIsPreserved の `session.rawOutputPath!=nil`: verifyRawNote が .notRecorded で先に偽にする
    /// - skipReasonIsBacked の `!sameKey(twin.part.partkey,c.part.partkey)`: 自分を双子にすると SKIPPED は deletable に無く根拠 A が偽
    /// - 同 `default:return false`: 許可リストに無い理由は nothingToPreserve の SkipReasons.deletable が先に落とす
    /// - 双子に deletionIsIdentified を要求しないこと: 双子の元音声は通常もう無いので、要求すると根拠 B が永久に偽（振る舞いは T-39 の正の対照が見る）
    /// 振る舞いでも落とせる項（形でも固定する。落とすテストは DeletionPolicyTests）:
    /// - deletionIsIdentified の `sameKey(c.part.sessionKey,c.session.sessionKey)`: partFromAnotherSessionIsNotIdentified
    /// - textIsPreserved の `frontmatterKeys(…).contains(…)`: frontmatterKeysAloneBlocksWhenExpectedIsEmpty（期待する鍵が空集合なら RN-6 は通る）
    /// - skipReasonIsBacked の `sameKey(twin.part.sessionKey,twin.session.sessionKey)`: twinSessionMismatchIsNotBacked
    static let expected: [String: String] = [
        "canDeleteSource":
            "deletionIsIdentified(c,ctx)&&(textIsPreserved(c.part,c.session,c.parts,ctx)||nothingToPreserve(c,ctx))",
        "deletionIsIdentified":
            "ctx.locks.allReleased(for:c.part.deviceID)&&sameKey(c.part.sessionKey,c.session.sessionKey)"
            + "&&c.parts.count>=1&&c.part.sourcePath!=nil&&c.part.sourcePath?.isEmpty==false&&preIdentityCheck(c.part,ctx)",
        "textIsPreserved":
            "session.rawOutputPath!=nil&&verifyRawNote(session,parts,ctx)==.passed"
            + "&&frontmatterKeys(session.rawOutputPath,ctx).contains(where:{sameKey($0,part.partkey)})"
            + "&&PartStates.deletable.contains(part.status)&&part.transcriptPath!=nil&&partTranscriptIsValid(part,ctx)",
        "nothingToPreserve":
            "ctx.config.cleanup.deleteSkippedSource==true&&c.part.status==.skipped"
            + "&&SkipReasons.deletable.contains(where:{$0==c.part.errorCode})&&skipReasonIsBacked(c,ctx)",
        "skipReasonIsBacked":
            "switch c.part.errorCode{case.noSpeechDetected:return partTranscriptIsValid(c.part,ctx)"
            + "case.duplicateContent:guard let twinKey=c.part.duplicateOf,let twin=c.twin,sameKey(twin.part.partkey,twinKey),"
            + "!sameKey(twin.part.partkey,c.part.partkey),sameKey(twin.part.sessionKey,twin.session.sessionKey)"
            + "else{return false}return textIsPreserved(twin.part,twin.session,twin.parts,ctx)default:return false}",
    ]

    struct Missing: Error, CustomStringConvertible { let description: String }

    /// トークンを連結する。識別子・数値が隣り合う所だけ空白 1 つ。
    static func normalized(_ tokens: [CodeToken]) -> String {
        var out = ""
        var previousIsWord = false
        for token in tokens {
            let isWord = token.kind == .identifier || token.kind == .number
            if isWord && previousIsWord { out += " " }
            out += token.text
            previousIsWord = isWord
        }
        return out
    }

    /// `func <name>(` の本体（外側の `{` `}` を除く。先頭の `return` も除く）を normalized にする。
    static func normalizedBody(_ function: String) throws -> String {
        let text = try String(contentsOf: PackageRoot.file("Sources/" + path), encoding: .utf8)
        let file = SourceFile(relativePath: path, text: text)
        guard let body = OrderingPolicy.body(of: function, in: file.tokens) else {
            throw Missing(description: "\(path) に func \(function)( が無い")
        }
        var inner = Array(body.dropFirst().dropLast())
        if inner.first?.kind == .identifier && inner.first?.text == "return" { inner.removeFirst() }
        return normalized(inner)
    }

    @Test(
        "TEST-30 削除条件の式の形を固定する",
        arguments: [
            "canDeleteSource", "deletionIsIdentified", "textIsPreserved", "nothingToPreserve", "skipReasonIsBacked",
        ])
    func formulaShapeIsFixed(_ function: String) throws {
        let want = try #require(Self.expected[function])
        #expect(try Self.normalizedBody(function) == want)
    }

    @Test("期待値の表が 5 つの関数を過不足なく持つ")
    func expectedCoversTheFormula() {
        #expect(
            Set(Self.expected.keys) == [
                "canDeleteSource", "deletionIsIdentified", "textIsPreserved", "nothingToPreserve", "skipReasonIsBacked",
            ])
    }

    @Test("正規化はコメントと空白を無視し、語の間だけ空白を残す（自己テスト）")
    func normalizationSelfTest() {
        let source = "func f() -> Bool {\n    // コメント\n    return a.b(c: 1) >= 2\n        && !x?.isEmpty\n}\n"
        let file = SourceFile(relativePath: "X.swift", text: source)
        let body = OrderingPolicy.body(of: "f", in: file.tokens)
        #expect(body.map { Self.normalized(Array($0.dropFirst().dropLast())) } == "return a.b(c:1)>=2&&!x?.isEmpty")
    }
}
