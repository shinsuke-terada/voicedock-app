// docs/POC.md 章 15 に貼る Markdown を作る（PLAN §10.6 の 5。T-24 §4.8）。
import Darwin
import Foundation
import TestSupport
import VDCore
import VDLLM

/// 報告の見出しの表に入れる値（測った環境）。
struct AcceptanceReportContext: Sendable {
    /// 測定日（yyyy-MM-dd）。
    let date: String
    let modelID: String
    let file: String
    /// `FileHasher.sha256(of:chunkBytes: 1_048_576)` の実測。
    let sha256: String
    /// `machdep.cpu.brand_string`。
    let machine: String
    /// `hw.memsize`（バイト）。
    let memoryBytes: UInt64
    /// `Vendor/versions.env` の LLAMA_CPP_REF。
    let llamaRef: String
}

enum AcceptanceReport {
    /// sha256 を測るときの読み込みの単位（§4.8）。
    static let hashChunkBytes = 1_048_576

    /// 測った環境を集める（モデルのファイルを読むだけ）。
    static func context(modelID: String, modelURL: URL, date: String) -> AcceptanceReportContext {
        AcceptanceReportContext(
            date: date, modelID: modelID, file: modelURL.lastPathComponent,
            sha256: (try? FileHasher.sha256(of: modelURL, chunkBytes: hashChunkBytes)) ?? "（測れませんでした）",
            machine: sysctlString("machdep.cpu.brand_string") ?? "（不明）",
            memoryBytes: sysctlUInt64("hw.memsize") ?? 0,
            llamaRef: versionsValue("LLAMA_CPP_REF") ?? "（不明）")
    }

    /// 章 15 の Markdown（§4.8 の形）。15.1 は scripts/check-catalog.sh の出力を人が貼る。
    static func render(_ c: AcceptanceReportContext, runs: [AcceptanceRun], verdict: AcceptanceVerdict) -> String {
        var lines: [String] = []
        lines.append("## 15. LLM 受け入れ試験（PLAN §10.6）")
        lines.append("")
        lines.append("測定日 **\(c.date)**。参照機は章 1 の機種。")
        lines.append("")
        lines.append("### 15.1 カタログの再確認")
        lines.append("")
        lines.append("`scripts/check-catalog.sh` の生の出力:")
        lines.append("")
        lines.append("```text")
        lines.append("<出力をそのまま>")
        lines.append("```")
        lines.append("")
        lines.append("判定: ⬜ 未実施（scripts/check-catalog.sh の出力を貼ってから ✅ PASS／✗ FAIL を書く）")
        lines.append("")
        lines.append("### 15.2 受け入れ試験")
        lines.append("")
        lines.append("| 項目 | 値 |")
        lines.append("|---|---|")
        lines.append("| モデル | `\(c.modelID)` |")
        lines.append("| ファイル | `\(c.file)` |")
        lines.append("| sha256 | `\(c.sha256)`（`FileHasher.sha256(of:chunkBytes: 1_048_576)` の実測） |")
        lines.append("| 機種 / メモリ | `\(c.machine)` / `\(c.memoryBytes)` |")
        lines.append("| llama.cpp | `\(c.llamaRef)`（`Vendor/versions.env`） |")
        lines.append("| コマンド | `make llm-acceptance MODEL=\(c.modelID)` |")
        lines.append("")
        lines.append("| fixture | 文字数 | 結果 | 本体の要求 | 修復の入った要求 | 所要 |")
        lines.append("|---|---|---|---|---|---|")
        for run in runs {
            let seconds = String(format: "%.1f s", AcceptanceJudge.seconds(run.elapsed))
            lines.append(
                "| \(run.fixtureID) | \(grouped(run.scalarCount)) | \(outcomeText(run.outcome)) | \(run.calls) "
                    + "| \(run.repairedCalls) | \(seconds) |")
        }
        lines.append("")
        lines.append("| 判定 | 基準 | 実測 | 結果 |")
        lines.append("|---|---|---|---|")
        let j1 = mark(verdict.j1)
        lines.append("| J1 ANALYZED | \(verdict.total) / \(verdict.total) | \(verdict.analyzed) | \(j1) |")
        let freeOK = verdict.repairFreeRate >= AcceptanceJudge.repairFreeThreshold
        lines.append("| J2 修復なしの割合 | ≥ 90% | \(percent(verdict.repairFreeRate))% | \(mark(freeOK)) |")
        lines.append(
            "| J2 修復込みの割合 | 100% | \(percent(verdict.repairedRate))% | \(mark(verdict.repairedRate == 1.0)) |")
        let j3Count = verdict.wikiLinkHits.count + verdict.badDue.count
        lines.append("| J3 `[[` と due | 0 件 | \(j3Count) 件 | \(mark(verdict.j3)) |")
        let minutes = String(format: "%.1f", verdict.longSeconds / 60)
        lines.append("| J4 350,000 文字 | ≤ 30 分 | \(minutes) 分 | \(mark(verdict.j4)) |")
        lines.append("")
        if verdict.passed {
            lines.append(
                "判定: ✅ PASS → `Resources/ModelCatalog.json` の `\(c.modelID)` を `verified: true` にした"
                    + "（コミット `<sha>`）")
        } else {
            lines.append("判定: ✗ FAIL → `Resources/ModelCatalog.json` の `\(c.modelID)` は `verified: false` のまま")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 3 桁ごとの `,`（例 5,012）。
    static func grouped(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (index, ch) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return n < 0 ? "-" + out : out
    }

    /// 小数 1 桁の百分率。
    static func percent(_ rate: Double) -> String {
        String(format: "%.1f", rate * 100)
    }

    static func mark(_ ok: Bool) -> String { ok ? "✅" : "✗" }

    static func outcomeText(_ outcome: AnalyzeOutcome) -> String {
        switch outcome {
        case .success: return "success"
        case .failure(let failure): return "failure（\(failure.code.rawValue)）"
        }
    }

    /// sysctlbyname の文字列。
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// sysctlbyname の 64 ビット整数。
    static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    /// `Vendor/versions.env` の `<key>=<value>` の値。
    static func versionsValue(_ key: String) -> String? {
        let url = PackageRoot.url.appendingPathComponent("Vendor/versions.env", isDirectory: false)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix(key + "=") {
            return String(line.dropFirst(key.count + 1))
        }
        return nil
    }
}
