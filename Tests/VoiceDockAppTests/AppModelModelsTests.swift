// AppModel のモデルの入手・選択・取り込み・キャンセルのテスト（T-31 §5.5）。ダウンロードは FakeServices の偽物で、ネットワークに出ない。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDModels

@testable import VoiceDockApp

@MainActor
@Suite("AppModel のモデル")
struct AppModelModelsTests {
    static let fixed = Instant(epochMillis: 1_756_000_000_000)
    static let layout = HomeLayout(root: URL(fileURLWithPath: "/tmp/voicedock-t31-layout", isDirectory: true))
    static let customID = "custom:" + String(repeating: "c", count: 64)

    /// whisper の項目（id "large-v3-turbo-q5_0"）が選ばれた観測
    static func present() -> AppSnapshot {
        var s = AppSnapshot(now: fixed)
        s.configPresent = true
        s.whisperEntry = TestCatalogs.minimal.whisper.first
        return s
    }

    static func choice(_ id: String, selectable: Bool) -> LLMChoice {
        LLMChoice(
            id: id, displayName: id, minMemoryGB: 1, present: false, selectable: selectable, note: nil, isCustom: false)
    }

    static func makeModel(_ fake: FakeServices, fileChooser: FakeFileChooser = FakeFileChooser(nil)) -> AppModel {
        AppModel(
            services: fake, openFinder: FakeFinder(), layout: layout, catalog: TestCatalogs.minimal,
            chooser: FakeFolderChooser(nil), fileChooser: fileChooser, presentModal: { $0() },
            sleeper: RecordingSleeper(), now: fixed, quit: {})
    }

    /// 条件が立つまで主アクターを譲る（上限つき。立たなければ偽）
    static func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<5_000 {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    @Test("進捗を出す")
    func fetchReportsProgress() async throws {
        let fake = FakeServices(Self.present())
        fake.setDownload(progress: [(1, 10), (5, 10)], result: .success(URL(fileURLWithPath: "/tmp/m")), hold: true)
        let model = Self.makeModel(fake)
        await model.refresh()
        let task = Task { await model.fetchModel(.whisper) }
        #expect(await Self.waitUntil { model.downloads[.whisper] == .running(received: 5, total: 10) })
        fake.releaseDownload()
        await task.value
        #expect(model.downloads[.whisper] == .idle)
    }

    @Test("二重に始めない")
    func fetchIsNotStartedTwice() async throws {
        let fake = FakeServices(Self.present())
        fake.setDownload(progress: [], result: .success(URL(fileURLWithPath: "/tmp/m")), hold: true)
        let model = Self.makeModel(fake)
        await model.refresh()
        let task = Task { await model.fetchModel(.whisper) }
        #expect(await Self.waitUntil { fake.heldDownloads == 1 })
        await model.fetchModel(.whisper)
        #expect(fake.downloadCount == 1)
        fake.releaseDownload()
        await task.value
        #expect(fake.downloadCount == 1)
    }

    @Test("失敗の文言")
    func fetchFailureShowsMessage() async throws {
        let fake = FakeServices(Self.present())
        fake.setDownload(progress: [], result: .failure(.sha256Mismatch))
        let model = Self.makeModel(fake)
        await model.refresh()
        await model.fetchModel(.whisper)
        #expect(model.downloads[.whisper] == .failed("SHA-256 が一致しません（壊れています。もう一度入手してください）"))
        #expect(model.modelError == "SHA-256 が一致しません（壊れています。もう一度入手してください）")
    }

    @Test("HTTP のコードを出す")
    func httpFailureShowsCode() async throws {
        let fake = FakeServices(Self.present())
        fake.setDownload(progress: [], result: .failure(.http(404)))
        let model = Self.makeModel(fake)
        await model.refresh()
        await model.fetchModel(.whisper)
        #expect(model.modelError == "配布元が HTTP 404 を返しました")
        #expect(model.downloads[.whisper] == .failed("配布元が HTTP 404 を返しました"))
    }

    @Test("やめたらエラーにしない")
    func cancelStopsAndDoesNotShowError() async throws {
        let fake = FakeServices(Self.present())
        fake.setDownload(progress: [], result: .failure(.cancelled), hold: true)
        let model = Self.makeModel(fake)
        await model.refresh()
        let task = Task { await model.fetchModel(.whisper) }
        #expect(await Self.waitUntil { fake.heldDownloads == 1 })
        await model.cancelModel(.whisper)
        fake.releaseDownload()
        await task.value
        #expect(model.downloads[.whisper] == .idle)
        #expect(model.modelError == nil)
        #expect(fake.cancelledIDs == ["large-v3-turbo-q5_0"])
    }

    @Test("取り消し後の遅れた進捗を捨てる")
    func lateProgressAfterCancelIsDropped() async throws {
        let fake = FakeServices(Self.present())
        fake.setDownload(progress: [], result: .failure(.cancelled), hold: true)
        let model = Self.makeModel(fake)
        await model.refresh()
        let task = Task { await model.fetchModel(.whisper) }
        #expect(await Self.waitUntil { fake.heldDownloads == 1 })
        await model.cancelModel(.whisper)
        fake.emitProgress(7, 10)
        for _ in 0..<50 { await Task.yield() }
        #expect(model.downloads[.whisper] == .idle)
        fake.releaseDownload()
        await task.value
        #expect(model.downloads[.whisper] == .idle)
    }

    @Test("入手の後に在否を読み直す")
    func fetchRefreshesPresence() async throws {
        let fake = FakeServices(Self.present())
        fake.setDownload(progress: [], result: .success(URL(fileURLWithPath: "/tmp/m")))
        let model = Self.makeModel(fake)
        await model.refresh()
        let before = fake.readCount
        await model.fetchModel(.whisper)
        #expect(fake.readCount == before + 1)
    }

    @Test("選ぶと設定に書く")
    func selectLLMWritesConfig() async throws {
        var s = Self.present()
        s.llmChoices = [Self.choice("test-llm", selectable: true)]
        let fake = FakeServices(s)
        let model = Self.makeModel(fake)
        await model.refresh()
        await model.selectLLM("test-llm")
        #expect(fake.updatedConfigs.count == 1)
        #expect(fake.updatedConfigs.first?.llm.modelID == "test-llm")
        #expect(model.modelError == nil)
    }

    @Test("選べないものは書かない")
    func selectLLMRejectsUnselectable() async throws {
        var s = Self.present()
        s.llmChoices = [Self.choice("big", selectable: false)]
        let fake = FakeServices(s)
        let model = Self.makeModel(fake)
        await model.refresh()
        await model.selectLLM("big")
        #expect(fake.updatedConfigs.isEmpty)
    }

    @Test("一覧に無い ID は書かない")
    func selectLLMRejectsUnknownID() async throws {
        var s = Self.present()
        s.llmChoices = [Self.choice("test-llm", selectable: true)]
        let fake = FakeServices(s)
        let model = Self.makeModel(fake)
        await model.refresh()
        await model.selectLLM("x")
        #expect(fake.updatedConfigs.isEmpty)
    }

    @Test("読み込んだら custom の ID を設定に書く")
    func importSetsCustomID() async throws {
        let source = URL(fileURLWithPath: "/tmp/voicedock-t31/picked.gguf")
        let fake = FakeServices(Self.present())
        fake.setImport(.success((id: Self.customID, url: URL(fileURLWithPath: "/tmp/voicedock-t31/custom.gguf"))))
        let model = Self.makeModel(fake, fileChooser: FakeFileChooser(source))
        await model.refresh()
        await model.importLLMFromFile()
        #expect(fake.importedSources == [source])
        #expect(fake.updatedConfigs.last?.llm.modelID == Self.customID)
        #expect(model.modelNotice == "動作保証外のモデルです")
        #expect(model.downloads[.customImport] == .idle)
    }

    @Test("読み込みの失敗")
    func importFailureShowsMessage() async throws {
        let fake = FakeServices(Self.present())
        fake.setImport(.failure(.io("EIO")))
        let model = Self.makeModel(fake, fileChooser: FakeFileChooser(URL(fileURLWithPath: "/tmp/x.gguf")))
        await model.refresh()
        await model.importLLMFromFile()
        #expect(model.modelError == "ファイルを扱えません: EIO")
        #expect(model.downloads[.customImport] == .failed("ファイルを扱えません: EIO"))
        #expect(fake.updatedConfigs.isEmpty)
    }

    @Test("ファイルを選ばなければ何もしない")
    func importCancelChangesNothing() async throws {
        let fake = FakeServices(Self.present())
        let chooser = FakeFileChooser(nil)
        let model = Self.makeModel(fake, fileChooser: chooser)
        await model.refresh()
        await model.importLLMFromFile()
        #expect(chooser.calls == 1)
        #expect(fake.importedSources.isEmpty)
        #expect(fake.updatedConfigs.isEmpty)
    }

    @Test("TEST-28 選択肢が 0 件")
    func emptyChoicesDoNothing() async throws {
        var s = Self.present()
        s.llmChoices = []
        let fake = FakeServices(s)
        let model = Self.makeModel(fake)
        await model.refresh()
        await model.selectLLM("a")
        #expect(fake.updatedConfigs.isEmpty)
    }
}
