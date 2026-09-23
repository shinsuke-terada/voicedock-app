// 既定の device.includeVolumes を ["DJIMIC3"] にしても、既存の config.json の値は書き換えない（PLAN §6.1・§6.2・F-81・issue #119）。
// 既定値を書くのは config.json が無いとき（初回起動）だけ。HOME は一時ディレクトリ。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore

@testable import VDPipeline

@Suite("ConfigStore と既定の includeVolumes（F-81）")
struct ConfigStoreIncludeDefaultTests {
    struct Scene {
        let tmp: TempDirectory
        let layout: HomeLayout

        init() throws {
            tmp = try TempDirectory()
            layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
            try layout.createDirectories()
        }

        func store() -> ConfigStore {
            let clock = FixedClock(epochMillis: 1_788_040_812_000)
            let log = AppLog(
                sink: CapturingLogSink(), level: .debug, unsafeContent: false, zone: PipelineFixtures.zone, clock: clock
            )
            return ConfigStore(
                layout: layout, catalog: TestCatalogs.minimal, log: log, observeReaperConf: { .missing },
                defaultTimeZone: { "Asia/Tokyo" })
        }

        /// 既定値から includeVolumes だけを変えた config.json を書く（F-81 より前に書かれたファイルの形）
        func writeConfig(includeVolumes: [String]) throws -> [UInt8] {
            var config = AppConfig.defaults(timeZone: "Asia/Tokyo")
            config.device.includeVolumes = includeVolumes
            let data = try ConfigLoader.encode(config)
            try AtomicFile.write(data, to: layout.configFile)
            return Array(data)
        }

        func fileBytes() throws -> [UInt8] { Array(try Data(contentsOf: layout.configFile)) }

        func fileIncludeVolumes() throws -> [String] {
            try JSONDecoder().decode(AppConfig.self, from: try Data(contentsOf: layout.configFile)).device
                .includeVolumes
        }
    }

    @Test("F-81 config.json が無ければ、既定の includeVolumes（DJIMIC3 だけ）を書く")
    func absentConfigGetsDJIMIC3Default() async throws {
        let s = try Scene()
        let store = s.store()
        _ = await store.load()
        #expect(await store.didCreateDefaults() == true)
        #expect(try s.fileIncludeVolumes() == ["DJIMIC3"])
        #expect(await store.current()?.device.includeVolumes == ["DJIMIC3"])
    }

    @Test("F-81 既存の config.json の includeVolumes が空なら、書き換えずに空のまま使う（TEST-28）")
    func existingEmptyIncludeIsKept() async throws {
        let s = try Scene()
        let written = try s.writeConfig(includeVolumes: [])
        let store = s.store()
        _ = await store.load()
        #expect(await store.didCreateDefaults() == false)
        #expect(await store.current()?.device.includeVolumes == [])
        #expect(try s.fileBytes() == written)
    }

    @Test("F-81 既存の config.json の includeVolumes に別の名前があれば、書き換えずにそのまま使う")
    func existingCustomIncludeIsKept() async throws {
        let s = try Scene()
        let written = try s.writeConfig(includeVolumes: ["MYMIC", "DJIMIC*"])
        let store = s.store()
        _ = await store.load()
        #expect(await store.current()?.device.includeVolumes == ["MYMIC", "DJIMIC*"])
        #expect(try s.fileBytes() == written)
    }
}
