// 根拠 B の「デバイスに今在るものだけ」の絞り込みがソースに在ることを固定する（PLAN §8.9.5・TEST-30。T-39）。
// 式の事前確認が同じ条件を見るので振る舞いでは落とせない（費用の規則: 過去の SKIPPED の件数に比例して読まない）。
import Foundation
import TestSupport
import Testing

@Suite("SkippedSettlerShape")
struct SkippedSettlerShapeTests {
    static let path = "VDPipeline/SkippedSettler.swift"
    /// 絞り込み（snapshot の devices と relpaths を見る）
    static let filter =
        "let present=skipped.filter{p in guard let rel=p.sourcePath,let obs=snapshot.devices[p.deviceID]"
        + "else{return false}return obs.relpaths.contains(where:{DeletionPolicy.sameKey($0,rel)})}"
    /// 要求のループ（絞り込んだ集合を回す）
    static let loop = "for stale in present{"

    /// settleSkippedDeletions の本体を DeletionFormulaTests.normalized で連結したもの。関数が無ければ nil
    static func normalizedBody(_ text: String) -> String? {
        let file = SourceFile(relativePath: path, text: text)
        guard let body = OrderingPolicy.body(of: "settleSkippedDeletions", in: file.tokens) else { return nil }
        return DeletionFormulaTests.normalized(Array(body.dropFirst().dropLast()))
    }

    /// 絞り込みが在り、要求のループより前にあること
    static func filterPrecedesLoop(_ body: String) -> Bool {
        guard let f = body.range(of: filter), let l = body.range(of: loop) else { return false }
        return f.upperBound <= l.lowerBound
    }

    @Test("TEST-30 SkippedSettler は要求のループの前に snapshot.devices[ でデバイスに在るものへ絞り込む")
    func deviceFilterPrecedesTheLoop() throws {
        let text = try String(contentsOf: PackageRoot.file("Sources/" + Self.path), encoding: .utf8)
        let body = try #require(Self.normalizedBody(text))
        #expect(body.contains("snapshot.devices["))
        #expect(Self.filterPrecedesLoop(body))
    }

    @Test("検査自体の対照: 絞り込みが無いか、ループの後にあれば偽（前にあれば真）")
    func checkerRejectsMissingOrLateFilter() {
        let loopOnly =
            "func settleSkippedDeletions() async -> Int {\n    for stale in present {\n    }\n    return 0\n}\n"
        #expect(Self.normalizedBody(loopOnly).map(Self.filterPrecedesLoop) == false)
        let late =
            "func settleSkippedDeletions() async -> Int {\n    for stale in present {\n    }\n"
            + "    let present = skipped.filter { p in\n"
            + "        guard let rel = p.sourcePath, let obs = snapshot.devices[p.deviceID] else { return false }\n"
            + "        return obs.relpaths.contains(where: { DeletionPolicy.sameKey($0, rel) })\n    }\n    return 0\n}\n"
        #expect(Self.normalizedBody(late).map(Self.filterPrecedesLoop) == false)
        // 陽性: 絞り込みがループの前にあれば真
        let right =
            "func settleSkippedDeletions() async -> Int {\n"
            + "    let present = skipped.filter { p in\n"
            + "        guard let rel = p.sourcePath, let obs = snapshot.devices[p.deviceID] else { return false }\n"
            + "        return obs.relpaths.contains(where: { DeletionPolicy.sameKey($0, rel) })\n    }\n"
            + "    for stale in present {\n    }\n    return 0\n}\n"
        #expect(Self.normalizedBody(right).map(Self.filterPrecedesLoop) == true)
    }

    @Test("空のソースには関数が無い（TEST-28）")
    func emptySourceHasNoBody() {
        #expect(Self.normalizedBody("") == nil)
    }
}
