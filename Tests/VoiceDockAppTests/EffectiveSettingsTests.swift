// 起動で時刻帯とログに使った値と、今の設定から解いた値の違い（F-84・issue #119 の G10。「再起動すると反映されます」の案内）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDPipeline

@testable import VoiceDockApp

@MainActor
@Suite("EffectiveSettings（F-84）")
struct EffectiveSettingsTests {
    static func config(timeZone: String, level: String, unsafe: Bool) -> AppConfig {
        var c = AppConfig.defaults(timeZone: timeZone)
        c.logging.level = level
        c.logging.unsafeLogContent = unsafe
        return c
    }

    @Test("F-84 設定が無ければ起動の既定（current の時刻帯・INFO・本文を出さない）")
    func resolveWithoutConfig() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let s = EffectiveSettings.resolve(nil, current: tokyo)
        #expect(s == EffectiveSettings(timeZoneID: "Asia/Tokyo", logLevel: .info, unsafeLogContent: false))
    }

    @Test("F-84 設定から解く（時刻帯・ログのレベル・本文を出すか）")
    func resolveFromConfig() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let s = EffectiveSettings.resolve(
            Self.config(timeZone: "America/New_York", level: "DEBUG", unsafe: true), current: tokyo)
        #expect(s == EffectiveSettings(timeZoneID: "America/New_York", logLevel: .debug, unsafeLogContent: true))
        #expect(s.timeZone.identifier == "America/New_York")
    }

    @Test("F-84 起動で使った値と同じなら違いは 0 件（TEST-28）")
    func noDifference() {
        let running = EffectiveSettings(timeZoneID: "Asia/Tokyo", logLevel: .info, unsafeLogContent: false)
        let c = Self.config(timeZone: "Asia/Tokyo", level: "INFO", unsafe: false)
        #expect(EffectiveSettings.differences(running: running, config: c) == [])
    }

    @Test("F-84 時刻帯は解いた後の値で比べる（別名の UTC は起動で使った GMT と同じ）")
    func aliasIsNotADifference() {
        let running = EffectiveSettings(timeZoneID: "GMT", logLevel: .info, unsafeLogContent: false)
        let c = Self.config(timeZone: "UTC", level: "INFO", unsafe: false)
        #expect(EffectiveSettings.resolve(c).timeZoneID == "GMT")
        #expect(EffectiveSettings.differences(running: running, config: c) == [])
    }

    @Test("F-84 設定エラー中は比べない（0 件。設定エラーの案内に任せる）")
    func noDifferenceWithoutConfig() {
        let running = EffectiveSettings(timeZoneID: "America/New_York", logLevel: .debug, unsafeLogContent: true)
        #expect(EffectiveSettings.differences(running: running, config: nil) == [])
    }

    @Test("F-84 違いは時刻帯・ログのレベル・本文を出すかの順に並ぶ")
    func differencesInOrder() {
        let running = EffectiveSettings(timeZoneID: "Asia/Tokyo", logLevel: .info, unsafeLogContent: true)
        let c = Self.config(timeZone: "America/New_York", level: "DEBUG", unsafe: false)
        #expect(
            EffectiveSettings.differences(running: running, config: c) == [
                .timeZone(running: "Asia/Tokyo", configured: "America/New_York"),
                .logLevel(running: .info, configured: .debug),
                .unsafeLogContent(running: true),
            ])
    }

    @Test("F-84 案内の文言（見出し・主画面の行の印・1 行ずつ。時刻帯の変更は促さない）")
    func texts() {
        #expect(
            Strings.restartPendingTitle
                == "次の設定は起動したときの値のまま動いています。「設定を読み直す」では変わらず、再起動すると変わります")
        #expect(Strings.restartPendingRow == "再起動で反映される設定あり")
        #expect(
            Strings.restartPending(.timeZone(running: "Asia/Tokyo", configured: "America/New_York"))
                == "時刻帯: 起動したときの Asia/Tokyo のまま（設定は America/New_York）。取り込みの時刻とログは起動したときの時刻帯、"
                + "ほかの処理は設定の時刻帯で動いています。使い始めた後に時刻帯を変えると記録の時刻が混ざるので、"
                + "変えるつもりがなければ設定を元に戻してください")
        #expect(
            Strings.restartPending(.logLevel(running: .info, configured: .debug))
                == "ログのレベル: 起動したときの INFO のまま（設定は DEBUG）")
        #expect(
            Strings.restartPending(.unsafeLogContent(running: true))
                == "ログに本文を出す設定: 起動したときの「出す」のまま。再起動するまで、DEBUG の行には本文が出続けます")
        #expect(Strings.restartPending(.unsafeLogContent(running: false)) == "ログに本文を出す設定: 起動したときの「出さない」のまま")
        #expect(Strings.logLevelWord(.warning) == "WARNING")
    }

    @Test("F-84 LiveServices の read は今の設定と起動で使った値の違いを snapshot に入れる（読むたびに作り直す）")
    func liveReadComparesWithRunningSettings() async throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let (services, layout) = try AppModelTests.liveServices(tmp)
        try layout.createDirectories()
        // 設定が無ければ既定を書く（時刻帯は TimeZone.current。起動で使った値と同じ）
        _ = await services.context.config.load()
        #expect(await services.read(lastConnectedAt: nil).settingsAwaitingRestart == [])
        // 手で DEBUG にして読み直した後
        _ = await services.context.config.update({ $0.logging.level = "DEBUG" })
        #expect(
            await services.read(lastConnectedAt: nil).settingsAwaitingRestart == [
                .logLevel(running: .info, configured: .debug)
            ])
        // 元に戻せば消える
        _ = await services.context.config.update({ $0.logging.level = "INFO" })
        #expect(await services.read(lastConnectedAt: nil).settingsAwaitingRestart == [])
    }
}
