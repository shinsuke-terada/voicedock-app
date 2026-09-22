// 診断（PLAN §8.11）。何も書き換えない（PT-17）。voicedock doctor.py:589-674 と同じ実行規則。
import VDCore

/// 診断（PLAN §8.11）。登録表・実行規則・サマリ。
public struct Diagnostics: Sendable {
    let deps: DiagnosticsDependencies
    let checks: [DiagnosticCheck]

    public init(deps: DiagnosticsDependencies) {
        self.init(deps: deps, checks: Self.checks)
    }

    /// テスト用（@testable）。検査の表を差し替える。
    init(deps: DiagnosticsDependencies, checks: [DiagnosticCheck]) {
        self.deps = deps
        self.checks = checks
    }

    /// PLAN §8.11 の表の順。宣言順 = 実行順（SPEC と突き合わせる）。DR-13 は取り下げ（PLAN F-61）。
    static let checks: [DiagnosticCheck] = [
        DiagnosticCheck(id: DiagnosticID.config, fatal: true, always: false, run: DiagnosticChecks.dr01),
        DiagnosticCheck(id: DiagnosticID.timeZone, fatal: true, always: false, run: DiagnosticChecks.dr16),
        DiagnosticCheck(id: DiagnosticID.database, fatal: true, always: false, run: DiagnosticChecks.dr02),
        DiagnosticCheck(id: DiagnosticID.space, fatal: false, always: false, run: DiagnosticChecks.dr03),
        DiagnosticCheck(id: DiagnosticID.whisperCLI, fatal: false, always: false, run: DiagnosticChecks.dr04),
        DiagnosticCheck(id: DiagnosticID.whisperModel, fatal: false, always: false, run: DiagnosticChecks.dr05),
        DiagnosticCheck(id: DiagnosticID.vadModel, fatal: false, always: false, run: DiagnosticChecks.dr06),
        DiagnosticCheck(id: DiagnosticID.llamaServer, fatal: false, always: false, run: DiagnosticChecks.dr07),
        DiagnosticCheck(id: DiagnosticID.llmModel, fatal: false, always: false, run: DiagnosticChecks.dr08),
        DiagnosticCheck(id: DiagnosticID.vault, fatal: false, always: false, run: DiagnosticChecks.dr10),
        DiagnosticCheck(id: DiagnosticID.devices, fatal: false, always: false, run: DiagnosticChecks.dr11),
        DiagnosticCheck(id: DiagnosticID.loginItem, fatal: false, always: false, run: DiagnosticChecks.dr12),
        DiagnosticCheck(id: DiagnosticID.leftovers, fatal: false, always: false, run: DiagnosticChecks.dr15),
        DiagnosticCheck(id: DiagnosticID.signature, fatal: false, always: false, run: DiagnosticChecks.dr17),
        DiagnosticCheck(id: DiagnosticID.deletion, fatal: false, always: true, run: DiagnosticChecks.dr14),
    ]

    /// 15 件を PLAN §8.11 の表の順に実行する。DR-09 は含まない（別のボタン）。
    public func run(loginItemStatus: LoginItemStatus) async -> [DiagnosticResult] {
        let config = await deps.config.current()
        let violations = await deps.config.violations()
        let snapshot = await deps.ingest.latestSnapshot()
        let ctx = DiagnosticsContext(
            deps: deps, config: config, violations: violations, snapshot: snapshot, loginItem: loginItemStatus,
            now: deps.clock.now())
        var results: [DiagnosticResult] = []
        var blocked = false
        for check in checks {
            // DR-14 は設定が読めていれば先行の fail でも実行する（voicedock doctor.py:640-641）
            if blocked && !(check.always && ctx.config != nil) {
                results.append(
                    DiagnosticResult(
                        id: check.id, status: .skip, label: DiagnosticTexts.label(check.id),
                        details: [DiagnosticTexts.skipped]))
                continue
            }
            let r = await check.run(ctx)
            results.append(r)
            if check.fatal && r.status == .fail { blocked = true }
        }
        let c = Self.counts(results)
        deps.log.info(
            .diagnosticsCompleted, [(.passed, .of(c.passed)), (.failed, .of(c.failed)), (.notices, .of(c.notices))])
        return results
    }

    /// 「合格 <n>・失敗 <n>・注意 <n>」（**skip は数えない**。voicedock doctor.py:669-674）
    public static func summary(_ results: [DiagnosticResult]) -> String {
        let c = counts(results)
        return "合格 " + String(c.passed) + "・失敗 " + String(c.failed) + "・注意 " + String(c.notices)
    }

    /// passed = ok の数、failed = fail の数、notices = notice の数（skip は数えない）
    public static func counts(_ results: [DiagnosticResult]) -> (passed: Int, failed: Int, notices: Int) {
        (
            results.filter { $0.status == .ok }.count, results.filter { $0.status == .fail }.count,
            results.filter { $0.status == .notice }.count
        )
    }
}
