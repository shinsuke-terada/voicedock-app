// 空き容量の 2 条件と想定バイト数の式（T-16 §6.2。PLAN §8.3「空き容量」）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore

@testable import VDAudio

@Suite("SpaceCheck")
struct SpaceCheckTests {
    private static func defaults() -> AudioConfig {
        AppConfig.defaults(timeZone: "Asia/Tokyo").audio
    }

    private static func home(_ tmp: TempDirectory) throws -> HomeLayout {
        let layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
        try layout.createDirectories()
        return layout
    }

    @Test(
        "想定バイト数の表",
        arguments: [
            (Double?.none, Int64(57_600_000)), (0, 0), (1.5, 48_000), (1800, 57_600_000), (-5, 0),
        ] as [(Double?, Int64)])
    func expectedBytesTable(duration: Double?, expected: Int64) {
        #expect(SpaceMath.expectedBytes(duration) == expected)
    }

    @Test("CE audio.freeSpaceMultiplier 必要量 = 想定 × 倍率 + 余裕")
    func requiredBytesUsesMultiplierAndMargin() {
        var config = Self.defaults()
        #expect(SpaceMath.requiredBytes(expected: 57_600_000, config: config) == 2_262_683_648)
        config.freeSpaceMultiplier = 4.0
        #expect(SpaceMath.requiredBytes(expected: 57_600_000, config: config) == 2_377_883_648)
    }

    @Test("空きが十分なら ok")
    func enoughSpacePasses() throws {
        let tmp = try TempDirectory()
        let layout = try Self.home(tmp)
        var config = Self.defaults()
        config.freeSpaceMarginBytes = 0
        #expect(SpaceCheck(config: config, layout: layout).check(durationSeconds: 1) == .ok)
    }

    @Test("CE audio.freeSpaceMarginBytes 空きが必要量を下回ると不足")
    func marginIsEnforced() throws {
        let tmp = try TempDirectory()
        let layout = try Self.home(tmp)
        var config = Self.defaults()
        #expect(SpaceCheck(config: config, layout: layout).check(durationSeconds: 1) == .ok)
        config.freeSpaceMarginBytes = Int(Int64.max / 4)
        let result = SpaceCheck(config: config, layout: layout).check(durationSeconds: 1)
        guard case .insufficient(let message) = result else {
            Issue.record("不足にならない: \(result)")
            return
        }
        #expect(message.hasPrefix("空き "))
        #expect(message.contains("バイトが必要量 "))
        #expect(message.contains(" バイトを下回る"))
    }

    @Test("CE audio.stagingMaxBytes staging の上限")
    func stagingCapIsEnforced() throws {
        let tmp = try TempDirectory()
        let layout = try Self.home(tmp)
        try Data(count: 80).write(to: layout.staging.appendingPathComponent("used.bin"))
        var config = Self.defaults()
        config.freeSpaceMarginBytes = 0
        #expect(SpaceCheck(config: config, layout: layout).check(durationSeconds: 0.001) == .ok)
        config.stagingMaxBytes = 100
        #expect(
            SpaceCheck(config: config, layout: layout).check(durationSeconds: 0.001)
                == .insufficient("staging 使用量 80 + 想定 32 が上限 100 を超える"))
    }

    @Test("上限ちょうどは ok")
    func stagingCapExactlyAtLimitPasses() throws {
        let tmp = try TempDirectory()
        let layout = try Self.home(tmp)
        try Data(count: 68).write(to: layout.staging.appendingPathComponent("used.bin"))
        var config = Self.defaults()
        config.freeSpaceMarginBytes = 0
        config.stagingMaxBytes = 100
        #expect(SpaceCheck(config: config, layout: layout).check(durationSeconds: 0.001) == .ok)
    }

    @Test("staging が無ければ使用量 0")
    func missingStagingCountsAsZero() throws {
        let tmp = try TempDirectory()
        let layout = try Self.home(tmp)
        try FileManager.default.removeItem(at: layout.staging)
        var config = Self.defaults()
        config.freeSpaceMarginBytes = 0
        config.stagingMaxBytes = 32
        #expect(!FileManager.default.fileExists(atPath: layout.staging.path(percentEncoded: false)))
        #expect(SpaceCheck(config: config, layout: layout).check(durationSeconds: 0.001) == .ok)
    }

    @Test("Int64 に収まらない長さでもトラップせず不足になる")
    func hugeDurationSaturates() throws {
        let tmp = try TempDirectory()
        let layout = try Self.home(tmp)
        #expect(SpaceMath.expectedBytes(.infinity) == Int64.max)
        #expect(SpaceMath.expectedBytes(1e300) == Int64.max)
        #expect(SpaceMath.requiredBytes(expected: Int64.max, config: Self.defaults()) == Int64.max)
        let result = SpaceCheck(config: Self.defaults(), layout: layout).check(durationSeconds: .infinity)
        guard case .insufficient(let message) = result else {
            Issue.record("不足にならない: \(result)")
            return
        }
        #expect(message.hasPrefix("空き "))
    }
}
