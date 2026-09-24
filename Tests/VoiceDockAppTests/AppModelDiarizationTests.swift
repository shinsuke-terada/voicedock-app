// AppModel の話者分離のトグルのテスト（T-51 §5）。書く・読むは一時ディレクトリの LiveServices、書けない場合は FakeServices。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore

@testable import VoiceDockApp

@MainActor
@Suite("AppModel の話者分離")
struct AppModelDiarizationTests {
    static let fixed = Instant(epochMillis: 1_756_000_000_000)

    static func makeModel(_ services: any AppServices, layout: HomeLayout) -> AppModel {
        AppModel(
            services: services, openFinder: FakeFinder(), layout: layout, catalog: TestCatalogs.minimal,
            chooser: FakeFolderChooser(nil), fileChooser: FakeFileChooser(nil), presentModal: { $0() },
            sleeper: RecordingSleeper(), now: fixed, quit: {})
    }

    /// 一時ディレクトリの LiveServices に既定の config.json を書かせる（helpers と resources は空の一時ディレクトリ）
    static func liveWithDefaults(_ tmp: TempDirectory) async throws -> (services: LiveServices, layout: HomeLayout) {
        let (services, layout) = try AppModelTests.liveServices(tmp)
        try layout.createDirectories()
        _ = await services.context.config.load()
        return (services, layout)
    }

    /// config.json のファイルに書かれた transcription.diarization.enabled（無ければ nil）
    static func enabledInFile(_ layout: HomeLayout) throws -> Bool? {
        let data = try Data(contentsOf: layout.configFile)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let transcription = object?["transcription"] as? [String: Any]
        let diarization = transcription?["diarization"] as? [String: Any]
        return diarization?["enabled"] as? Bool
    }

    @Test("オンにすると設定に true を書く")
    func turnOnWritesConfig() async throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let (services, layout) = try await Self.liveWithDefaults(tmp)
        #expect(try Self.enabledInFile(layout) == false)
        let model = Self.makeModel(services, layout: layout)
        await model.refresh()

        await model.setDiarization(true)

        #expect(try Self.enabledInFile(layout) == true)
        #expect(model.snapshot.diarizationEnabled == true)
        #expect(model.modelError == nil)
    }

    @Test("オフにすると false を書く")
    func turnOffWritesConfig() async throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let (services, layout) = try await Self.liveWithDefaults(tmp)
        _ = await services.context.config.update({ $0.transcription.diarization.enabled = true })
        #expect(try Self.enabledInFile(layout) == true)
        let model = Self.makeModel(services, layout: layout)
        await model.refresh()
        #expect(model.snapshot.diarizationEnabled == true)

        await model.setDiarization(false)

        #expect(try Self.enabledInFile(layout) == false)
        #expect(model.snapshot.diarizationEnabled == false)
    }

    @Test("書けなければ modelError")
    func rejectedShowsError() async throws {
        var s = AppSnapshot(now: Self.fixed)
        s.configPresent = true
        let fake = FakeServices(s)
        fake.setUpdateViolations([
            ConfigViolation(
                rule: "CV-39", code: .configInvalidValue, keyPath: "transcription.diarization.enabled", message: "x")
        ])
        let layout = HomeLayout(root: URL(fileURLWithPath: "/tmp/voicedock-t51-layout", isDirectory: true))
        let model = Self.makeModel(fake, layout: layout)
        await model.refresh()

        await model.setDiarization(true)

        #expect(fake.updatedConfigs.last?.transcription.diarization.enabled == true)
        #expect(
            model.modelError
                == "設定に書けませんでした: CV-39  CONFIG_INVALID_VALUE  transcription.diarization.enabled: x")
    }

    @Test("オンで部品が欠ければ snapshot に載る")
    func missingPartsShown() async throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let (services, layout) = try await Self.liveWithDefaults(tmp)
        _ = await services.context.config.update({ $0.transcription.diarization.enabled = true })
        let model = Self.makeModel(services, layout: layout)

        await model.refresh()

        #expect(model.snapshot.diarizationEnabled == true)
        #expect(model.snapshot.diarizationMissing == ["argmax-cli", "SpeakerModels"])
    }

    @Test("オフなら欠けを見ない（TEST-28: 空）")
    func offHasNoMissing() async throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let (services, layout) = try await Self.liveWithDefaults(tmp)
        let model = Self.makeModel(services, layout: layout)

        await model.refresh()

        #expect(model.snapshot.configPresent == true)
        #expect(model.snapshot.diarizationEnabled == false)
        #expect(model.snapshot.diarizationMissing == [])
    }

    @Test("文言が逐語")
    func stringsAreVerbatim() {
        #expect(Strings.labelDiarization == "話者分離（誰が話したか）")
        #expect(
            Strings.diarizationNote
                == "オンにした後に文字起こしする録音から、Raw ノートを「話者A: …」の行に分けます。精度は録音の条件で変わります。")
        #expect(
            Strings.diarizationMissing(["argmax-cli", "SpeakerModels"])
                == "話者分離の部品がありません（argmax-cli、SpeakerModels）。話者なしで文字起こしします")
    }
}
