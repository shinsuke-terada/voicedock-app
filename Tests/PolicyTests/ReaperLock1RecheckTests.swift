// reaper の unlink（RV-13）は必ず reaper.conf の読み直し（unlinkIfLock1Open）を経由する（PLAN §8.9.4・F-73・issue #113）。
// RV-13 まで進む経路は普通のディレクトリでは RV-06 で弾かれ、層 R1 のふるまいのテストで観測できないため、トークンで固定する
// （読み直しそのものは ReaperDefenseTests がプロセス内で確かめる）。
import Foundation
import TestSupport
import Testing

@Suite("reaper の unlink の直前の読み直し（F-73）")
struct ReaperLock1RecheckTests {
    static let processorPath = "voicedock-reaper/RequestProcessor.swift"
    static let reaperDirectory = "voicedock-reaper/"

    /// `func` の直後でない `name(` の位置（呼び出し）
    static func calls(_ name: String, in tokens: ArraySlice<CodeToken>) -> [Int] {
        tokens.indices.filter { index in
            index + 1 < tokens.endIndex && tokens[index].kind == .identifier && tokens[index].text == name
                && tokens[index + 1].text == "(" && (index == tokens.startIndex || tokens[index - 1].text != "func")
        }
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

    static let good = """
        struct RequestProcessor {
            mutating func process(name: String) -> RequestOutcome {
                let outcome = TargetIdentity.withVerifiedTarget(volume: volume) { target in
                    Self.unlinkIfLock1Open(target, confURL: confURL)
                }
            }
            static func unlinkIfLock1Open(_ target: VerifiedTarget, confURL: URL) -> UnlinkStep {
                if let reason = lock1ClosedReason(ReaperConf.observe(at: confURL)) { return .lock1Closed(reason) }
                return .unlinked(Unlinker.unlinkTarget(target))
            }
        }
        """

    static let bypassed = """
        struct RequestProcessor {
            mutating func process(name: String) -> RequestOutcome {
                let outcome = TargetIdentity.withVerifiedTarget(volume: volume) { target in
                    Unlinker.unlinkTarget(target)
                }
            }
            static func unlinkIfLock1Open(_ target: VerifiedTarget, confURL: URL) -> UnlinkStep {
                if let reason = lock1ClosedReason(ReaperConf.observe(at: confURL)) { return .lock1Closed(reason) }
                return .unlinked(Unlinker.unlinkTarget(target))
            }
        }
        """

    static let unlinkFirst = """
        struct RequestProcessor {
            mutating func process(name: String) -> RequestOutcome {
                Self.unlinkIfLock1Open(target, confURL: confURL)
            }
            static func unlinkIfLock1Open(_ target: VerifiedTarget, confURL: URL) -> UnlinkStep {
                let step = UnlinkStep.unlinked(Unlinker.unlinkTarget(target))
                if let reason = lock1ClosedReason(ReaperConf.observe(at: confURL)) { return .lock1Closed(reason) }
                return step
            }
        }
        """

    @Test(
        "F-73 自己テスト: 読み直しを経由しない unlink・読み直しより先の unlink・読み直しの欠落を検出する",
        arguments: [
            (good, [String]()),
            (
                bypassed,
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
