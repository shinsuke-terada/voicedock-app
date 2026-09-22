// Diagnostics の実行規則・サマリ・diagnostics_completed のテスト（T-32 §5.1）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDPipeline

@Suite("Diagnostics の実行規則")
struct DiagnosticsRunTests {
    /// 固定の結果を返す偽の検査
    static func check(_ id: String, _ status: DiagnosticStatus, fatal: Bool = false, always: Bool = false)
        -> DiagnosticCheck
    {
        DiagnosticCheck(id: id, fatal: fatal, always: always) { _ in
            DiagnosticResult(id: id, status: status, label: id)
        }
    }

    static func result(_ status: DiagnosticStatus) -> DiagnosticResult {
        DiagnosticResult(id: "DR-01", status: status, label: "設定")
    }

    @Test("15 件が PLAN §8.11 の順")
    func orderIsTheSpecOrder() throws {
        #expect(
            Diagnostics.checks.map(\.id) == [
                "DR-01", "DR-16", "DR-02", "DR-03", "DR-04", "DR-05", "DR-06", "DR-07", "DR-08", "DR-10", "DR-11",
                "DR-12", "DR-15", "DR-17", "DR-14",
            ])
        // SPEC の S6 の表（DR-09 は別のボタン）と同じ集合・順（T-32 §8）
        let spec = try SpecDocument.load().ids(.dr).filter { $0 != "DR-09" }
        #expect(Diagnostics.checks.map(\.id) == spec)
    }

    @Test("DR-09 を除いて 15 件")
    func countIs15() {
        let ids = Diagnostics.checks.map(\.id)
        #expect(Diagnostics.checks.count == 15)
        #expect(!ids.contains("DR-09"))
        #expect(!ids.contains("DR-13"))
    }

    @Test("always は DR-14 だけ")
    func onlyDR14IsAlways() {
        #expect(Diagnostics.checks.filter(\.always).map(\.id) == ["DR-14"])
    }

    @Test("致命は DR-01 / DR-16 / DR-02 の 3 つ")
    func fatalSetIsTheSpecSet() {
        #expect(Diagnostics.checks.filter(\.fatal).map(\.id) == ["DR-01", "DR-16", "DR-02"])
    }

    @Test("致命の fail 以降は skip")
    func fatalFailSkipsTheRest() async throws {
        let w = try await DiagnosticsWorld.make()
        let checks = [
            Self.check("DR-01", .ok, fatal: true), Self.check("DR-16", .fail, fatal: true), Self.check("DR-03", .ok),
            Self.check("DR-04", .ok),
        ]
        let results = await Diagnostics(deps: w.deps, checks: checks).run(loginItemStatus: .enabled)
        #expect(results.map(\.status) == [.ok, .fail, .skip, .skip])
        #expect(results[2].details == ["先行する致命的な検査が失敗"])
        #expect(results[3].details == ["先行する致命的な検査が失敗"])
        #expect(results[2].label == "空き容量")
    }

    @Test("always は先行の fail でも実行する")
    func alwaysRunsAfterFatalFail() async throws {
        let w = try await DiagnosticsWorld.make()
        let checks = [
            Self.check("DR-01", .fail, fatal: true), Self.check("DR-03", .ok),
            Self.check("DR-14", .notice, always: true),
        ]
        let results = await Diagnostics(deps: w.deps, checks: checks).run(loginItemStatus: .enabled)
        #expect(results.map(\.status) == [.fail, .skip, .notice])
    }

    @Test("設定が読めないときは always も skip")
    func alwaysSkipsWhenConfigIsNil() async throws {
        let w = try await DiagnosticsWorld.make(loadConfig: false)
        let checks = [Self.check("DR-01", .fail, fatal: true), Self.check("DR-14", .notice, always: true)]
        let results = await Diagnostics(deps: w.deps, checks: checks).run(loginItemStatus: .enabled)
        #expect(results.map(\.status) == [.fail, .skip])
        #expect(results[1].details == ["先行する致命的な検査が失敗"])
    }

    @Test("致命でない fail は止めない")
    func nonFatalFailDoesNotBlock() async throws {
        let w = try await DiagnosticsWorld.make()
        let checks = [Self.check("DR-03", .fail), Self.check("DR-04", .ok)]
        let results = await Diagnostics(deps: w.deps, checks: checks).run(loginItemStatus: .enabled)
        #expect(results.map(\.status) == [.fail, .ok])
    }

    @Test("サマリは skip を数えない")
    func summaryDoesNotCountSkip() {
        let results = [
            Self.result(.ok), Self.result(.ok), Self.result(.fail), Self.result(.notice), Self.result(.skip),
            Self.result(.skip), Self.result(.skip),
        ]
        #expect(Diagnostics.summary(results) == "合格 2・失敗 1・注意 1")
        let c = Diagnostics.counts(results)
        #expect(c.passed == 2 && c.failed == 1 && c.notices == 1)
    }

    @Test("TEST-28 0 件")
    func summaryOfEmpty() {
        #expect(Diagnostics.summary([]) == "合格 0・失敗 0・注意 0")
    }

    @Test("終わりに 1 行だけ出す")
    func logsDiagnosticsCompleted() async throws {
        let w = try await DiagnosticsWorld.make()
        let before = w.sink.lines.count
        let checks = [
            Self.check("DR-03", .ok), Self.check("DR-04", .ok), Self.check("DR-05", .fail),
            Self.check("DR-06", .notice),
        ]
        _ = await Diagnostics(deps: w.deps, checks: checks).run(loginItemStatus: .enabled)
        let lines = Array(w.sink.lines.dropFirst(before))
        #expect(lines.count == 1)
        #expect(lines.first?.hasSuffix(" diagnostics_completed passed=2 failed=1 notices=1") == true)
        #expect(lines.first?.contains(" INFO ") == true)
    }
}
