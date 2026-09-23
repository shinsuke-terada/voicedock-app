// reaper の unlink（RV-13）は必ず reaper.conf の読み直し（unlinkIfLock1Open）を経由し、ロック 1 が閉じていた分岐
// （`.lock1Closed`）は何も書かずに return する（PLAN §8.9.4・F-73・issue #113）。
// RV-13 まで進む経路は普通のディレクトリでは RV-06 で弾かれ、層 R1 のふるまいのテストで観測できないため、トークンで固定する
// （読み直しそのものは ReaperDefenseTests がプロセス内で、分岐のふるまいは ReaperDefenseDiskImageTests が層 R3 で確かめる）。
import Foundation
import TestSupport
import Testing

@Suite("reaper の unlink の直前の読み直し（F-73）")
struct ReaperLock1RecheckTests {
    static let processorPath = "voicedock-reaper/RequestProcessor.swift"
    static let reaperDirectory = "voicedock-reaper/"
    /// `.lock1Closed` の分岐で return より前に呼んではいけないもの（processed.log・結果・要求・拒否・退避の書き込み）
    static let writes = ["append", "writeResult", "removeRequest", "refuse", "moveToRejected"]

    /// `func` の直後でない `name(` の位置（呼び出し）
    static func calls(_ name: String, in tokens: ArraySlice<CodeToken>) -> [Int] {
        tokens.indices.filter { index in
            index + 1 < tokens.endIndex && tokens[index].kind == .identifier && tokens[index].text == name
                && tokens[index + 1].text == "(" && (index == tokens.startIndex || tokens[index - 1].text != "func")
        }
    }

    /// パターンに `.lock1Closed` を含む `case` の分岐の本体（`case … :` の `:` の後から、同じ深さの次の `case` / `default`
    /// か、switch を閉じる `}` の手前まで）。無ければ nil
    static func lock1ClosedArm(in body: ArraySlice<CodeToken>) -> ArraySlice<CodeToken>? {
        for start in body.indices where body[start].kind == .identifier && body[start].text == "case" {
            // パターンの終わり（括弧の外の最初の `:`）
            var parens = 0
            var colon: Int? = nil
            for index in (start + 1)..<body.endIndex {
                let text = body[index].text
                if text == "(" { parens += 1 }
                if text == ")" { parens -= 1 }
                if text == ":" && parens == 0 {
                    colon = index
                    break
                }
                if text == "{" || text == "}" { break }
            }
            guard let colon else { continue }
            let pattern = body[(start + 1)..<colon]
            guard
                pattern.indices.contains(where: {
                    pattern[$0].text == "lock1Closed" && $0 > pattern.startIndex && pattern[$0 - 1].text == "."
                })
            else { continue }
            var braces = 0
            var end = body.endIndex
            for index in (colon + 1)..<body.endIndex {
                let text = body[index].text
                if text == "{" { braces += 1 }
                if text == "}" {
                    if braces == 0 {
                        end = index
                        break
                    }
                    braces -= 1
                }
                if braces == 0 && body[index].kind == .identifier && (text == "case" || text == "default") {
                    end = index
                    break
                }
            }
            return body[(colon + 1)..<end]
        }
        return nil
    }

    /// 違反の説明（無ければ空）。files は voicedock-reaper/ の全ファイル
    static func violations(in files: [SourceFile]) -> [String] {
        guard let processor = files.first(where: { $0.relativePath == processorPath }) else {
            return ["RequestProcessor.swift がありません"]
        }
        var out: [String] = []
        if let process = OrderingPolicy.body(of: "process", in: processor.tokens) {
            if calls("unlinkIfLock1Open", in: process).isEmpty { out.append("process が unlinkIfLock1Open( を呼ばない") }
            if !calls("unlinkTarget", in: process).isEmpty { out.append("process が unlinkTarget( を直に呼ぶ") }
            if let arm = lock1ClosedArm(in: process) {
                let back = arm.indices.first { arm[$0].kind == .identifier && arm[$0].text == "return" }
                if back == nil { out.append("`.lock1Closed` の分岐が return しない") }
                for name in writes {
                    if let call = calls(name, in: arm).first, call < (back ?? arm.endIndex) {
                        out.append("`.lock1Closed` の分岐が return より前に " + name + "( を呼ぶ")
                    }
                }
            } else {
                out.append("process に `.lock1Closed` の分岐がありません")
            }
        } else {
            out.append("func process( がありません")
        }
        if let gate = OrderingPolicy.body(of: "unlinkIfLock1Open", in: processor.tokens) {
            let reread = calls("observe", in: gate).first
            let judge = calls("lock1ClosedReason", in: gate).first
            let unlink = calls("unlinkTarget", in: gate).first
            if reread == nil { out.append("unlinkIfLock1Open が reaper.conf を読み直さない（observe( が無い）") }
            if judge == nil { out.append("unlinkIfLock1Open が lock1ClosedReason( を呼ばない") }
            if let unlink, [reread, judge].compactMap({ $0 }).contains(where: { $0 > unlink }) {
                out.append("unlinkTarget( が読み直しより先")
            }
        } else {
            out.append("func unlinkIfLock1Open( がありません")
        }
        let total = files.filter { $0.relativePath.hasPrefix(reaperDirectory) }
            .reduce(0) { $0 + calls("unlinkTarget", in: $1.tokens[...]).count }
        if total != 1 { out.append("unlinkTarget( の呼び出しが unlinkIfLock1Open の 1 か所でない（\(total) か所）") }
        return out
    }

    @Test("RV-01 reaper の unlink（RV-13）は必ず unlinkIfLock1Open（reaper.conf の読み直し → 判定 → unlink）を経由する")
    func rv01UnlinkAlwaysGoesThroughTheRecheck() throws {
        let files = try SourceTree.load().filter { $0.relativePath.hasPrefix(Self.reaperDirectory) }
        #expect(Self.violations(in: files) == [])
    }

    @Test("RV-01 ロック 1 が閉じていた分岐（.lock1Closed）は processed.log・結果・要求に書く前に return する")
    func rv01Lock1ClosedArmReturnsBeforeWriting() throws {
        let files = try SourceTree.load().filter { $0.relativePath.hasPrefix(Self.reaperDirectory) }
        let processor = try #require(files.first { $0.relativePath == Self.processorPath })
        let process = try #require(OrderingPolicy.body(of: "process", in: processor.tokens))
        let arm = try #require(Self.lock1ClosedArm(in: process))
        #expect(arm.contains { $0.kind == .identifier && $0.text == "return" })
        #expect(Self.violations(in: files).filter { $0.hasPrefix("`.lock1Closed`") } == [])
    }

    static let good = """
        struct RequestProcessor {
            mutating func process(name: String) -> RequestOutcome {
                let outcome = TargetIdentity.withVerifiedTarget(volume: volume) { target in
                    Self.unlinkIfLock1Open(target, confURL: confURL)
                }
                switch outcome {
                case .failure(let mismatch):
                    return refuse(name: name, reason: mismatch.reason)
                case .success(.lock1Closed(let reason)):
                    log.info(ReaperLog.Event.disabled, [(ReaperLog.Key.reason, reason)])
                    return .stopped(reason)
                case .success(.unlinked(.ok)):
                    break
                }
                processed.append(stem)
                let written = queue.writeResult(result(stem: stem))
                if written { _ = Unlinker.removeRequest(named: name, inQueueDelete: queue.deleteFD) }
                return .deleted(relpath: relpath)
            }
            static func unlinkIfLock1Open(_ target: VerifiedTarget, confURL: URL) -> UnlinkStep {
                if let reason = lock1ClosedReason(ReaperConf.observe(at: confURL)) { return .lock1Closed(reason) }
                return .unlinked(Unlinker.unlinkTarget(target))
            }
        }
        """

    /// unlink してから読み直す形（改行と字下げはトークンに影響しない）
    static let unlinkFirst =
        good
        .replacingOccurrences(of: "return .unlinked(Unlinker.unlinkTarget(target))", with: "return step")
        .replacingOccurrences(
            of: "if let reason = lock1ClosedReason",
            with: "let step = UnlinkStep.unlinked(Unlinker.unlinkTarget(target))\n if let reason = lock1ClosedReason")

    @Test(
        "F-73 自己テスト: 読み直しを経由しない unlink・読み直しより先の unlink・読み直しの欠落・書いてから止まる分岐を検出する",
        arguments: [
            (good, [String]()),
            (
                good.replacingOccurrences(
                    of: "Self.unlinkIfLock1Open(target, confURL: confURL)", with: "Unlinker.unlinkTarget(target)"),
                [
                    "process が unlinkIfLock1Open( を呼ばない", "process が unlinkTarget( を直に呼ぶ",
                    "unlinkTarget( の呼び出しが unlinkIfLock1Open の 1 か所でない（2 か所）",
                ]
            ),
            (unlinkFirst, ["unlinkTarget( が読み直しより先"]),
            (
                good.replacingOccurrences(of: "ReaperConf.observe(at: confURL)", with: "cached"),
                ["unlinkIfLock1Open が reaper.conf を読み直さない（observe( が無い）"]
            ),
            (
                good.replacingOccurrences(of: "return .stopped(reason)", with: "break"),
                ["`.lock1Closed` の分岐が return しない"]
            ),
            (
                good.replacingOccurrences(
                    of: "log.info(ReaperLog.Event.disabled",
                    with: "processed.append(stem)\n            log.info(ReaperLog.Event.disabled"
                ),
                ["`.lock1Closed` の分岐が return より前に append( を呼ぶ"]
            ),
            (
                good.replacingOccurrences(of: "case .success(.lock1Closed(let reason)):", with: "default:"),
                ["process に `.lock1Closed` の分岐がありません"]
            ),
            (
                "",
                [
                    "func process( がありません", "func unlinkIfLock1Open( がありません",
                    "unlinkTarget( の呼び出しが unlinkIfLock1Open の 1 か所でない（0 か所）",
                ]
            ),
        ])
    func selfTest(_ source: String, _ expected: [String]) {
        #expect(Self.violations(in: [SourceFile(relativePath: Self.processorPath, text: source)]) == expected)
    }
}
