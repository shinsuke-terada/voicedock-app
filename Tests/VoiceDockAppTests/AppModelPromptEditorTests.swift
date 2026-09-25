// AppModel の要約プロンプトの編集（F-92）のテスト。書く・読むは FakeServices と一時ディレクトリの LiveServices。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDLLM

@testable import VoiceDockApp

/// 窓を出した回数（presentPromptEditor の差し替え）
@MainActor
final class PresentCounter {
    var count = 0
}

@MainActor
@Suite("AppModel の要約プロンプトの編集")
struct AppModelPromptEditorTests {
    static let bundled = Prompts(analyze: "既定A", map: "既定M", reduce: "既定R", repair: "修復")
    static let none = PromptOverrides(analyze: nil, map: nil, reduce: nil)
    static let valid = "新しい指示{custom_instructions}\n{schema_block}"

    static func makeModel(_ services: any AppServices, counter: PresentCounter) -> AppModel {
        let model = AppModelDiarizationTests.makeModel(services, layout: AppModelTests.layout)
        model.presentPromptEditor = { counter.count += 1 }
        return model
    }

    static func fake(saved: PromptOverrides = none) -> FakeServices {
        let fake = FakeServices(AppModelTests.present())
        fake.setPromptSources((bundled, saved))
        return fake
    }

    @Test("開くと同梱の本文と保存済みの上書きを読み、窓を出す。開いている間は読み直さない")
    func openLoadsOnceAndPresents() async {
        let fake = Self.fake(saved: PromptOverrides(analyze: nil, map: "保存M", reduce: nil))
        let counter = PresentCounter()
        let model = Self.makeModel(fake, counter: counter)

        await model.openPromptEditor()
        #expect(counter.count == 1)
        #expect(model.promptEditor?.draft(.analyze) == "既定A")
        #expect(model.promptEditor?.draft(.map) == "保存M")

        model.editPrompt("編集中")
        await model.openPromptEditor()
        #expect(counter.count == 2)
        #expect(fake.promptSourcesCount == 1)
        #expect(model.promptEditor?.draft(.analyze) == "編集中")
    }

    @Test("読めなければ窓を出さずに理由を出す")
    func openFailsWithoutSources() async {
        let fake = FakeServices(AppModelTests.present())
        let counter = PresentCounter()
        let model = Self.makeModel(fake, counter: counter)

        await model.openPromptEditor()
        #expect(counter.count == 0)
        #expect(model.promptEditor == nil)
        #expect(model.promptEditorError == "設定または同梱のプロンプトを読めません。「詳細・診断」の「設定を読み直す」を試してください")
    }

    @Test("保存は変えた種類だけを書き、「保存しました」を出す")
    func saveWritesOnlyChangedKinds() async {
        let fake = Self.fake(saved: PromptOverrides(analyze: nil, map: "保存M", reduce: "保存R"))
        let model = Self.makeModel(fake, counter: PresentCounter())
        await model.openPromptEditor()
        model.selectPromptKind(.reduce)
        model.editPrompt(Self.valid)

        await model.savePrompts()
        // FakeServices は既定の設定（上書きは全部 null）に変更を当てる。map は変えていないので null のまま
        #expect(
            fake.updatedConfigs.map(\.llm.analysis.prompts) == [
                PromptOverrides(analyze: nil, map: nil, reduce: Self.valid)
            ])
        #expect(model.promptEditorMessage == "保存しました")
        #expect(model.promptEditorError == nil)
        #expect(model.promptEditor?.hasChanges == false)
    }

    @Test("変更が無ければ書かない（TEST-28）")
    func saveWithoutChangesWritesNothing() async {
        let fake = Self.fake()
        let model = Self.makeModel(fake, counter: PresentCounter())
        await model.openPromptEditor()
        await model.savePrompts()
        #expect(fake.updatedConfigs.isEmpty)
        #expect(model.promptEditorMessage == nil)
    }

    @Test("既定に戻して保存すると null を書く")
    func resetThenSaveWritesNull() async {
        let fake = Self.fake(saved: PromptOverrides(analyze: Self.valid, map: nil, reduce: nil))
        let model = Self.makeModel(fake, counter: PresentCounter())
        await model.openPromptEditor()
        model.resetPromptToDefault()
        #expect(model.promptEditor?.draft(.analyze) == "既定A")
        #expect(fake.updatedConfigs.isEmpty)

        await model.savePrompts()
        #expect(fake.updatedConfigs.map(\.llm.analysis.prompts) == [Self.none])
    }

    @Test("CV-60 で断られたら書けなかった理由を出し、下書きを残す")
    func rejectedSaveKeepsDraft() async {
        let fake = Self.fake()
        let violation = ConfigViolation(
            rule: "CV-60", code: .configInvalidValue, keyPath: "llm.analysis.prompts.analyze",
            message: "{schema_block} を含むこと")
        fake.setUpdateViolations([violation])
        let model = Self.makeModel(fake, counter: PresentCounter())
        await model.openPromptEditor()
        model.editPrompt("壊れた指示")

        await model.savePrompts()
        #expect(
            model.promptEditorError
                == "設定に書けませんでした: CV-60  CONFIG_INVALID_VALUE  llm.analysis.prompts.analyze: {schema_block} を含むこと")
        #expect(model.promptEditorMessage == nil)
        #expect(model.promptEditor?.draft(.analyze) == "壊れた指示")
        #expect(model.promptEditor?.hasChanges == true)
    }

    @Test("断られた後に本文を直すと、書けなかった理由を消す")
    func editClearsError() async {
        let fake = Self.fake()
        fake.setUpdateViolations([
            ConfigViolation(
                rule: "CV-60", code: .configInvalidValue, keyPath: "llm.analysis.prompts.analyze",
                message: "{schema_block} を含むこと")
        ])
        let model = Self.makeModel(fake, counter: PresentCounter())
        await model.openPromptEditor()
        model.editPrompt("壊れた指示")
        await model.savePrompts()
        #expect(model.promptEditorError != nil)

        model.editPrompt(Self.valid)
        #expect(model.promptEditorError == nil)
    }

    @Test("書いている間に窓が閉じられたら、結果（失敗）を残さない")
    func closeDuringSaveLeavesNoError() async {
        let fake = Self.fake()
        fake.setUpdateViolations([
            ConfigViolation(
                rule: "CV-60", code: .configInvalidValue, keyPath: "llm.analysis.prompts.analyze",
                message: "{schema_block} を含むこと")
        ])
        let model = Self.makeModel(fake, counter: PresentCounter())
        await model.openPromptEditor()
        model.editPrompt("壊れた指示")
        fake.setHoldUpdate()
        let save = Task { await model.savePrompts() }
        while fake.heldUpdates == 0 { await Task.yield() }
        model.promptEditorDidClose()
        fake.releaseUpdate()
        await save.value
        #expect(model.promptEditor == nil)
        #expect(model.promptEditorError == nil)
    }

    @Test("読み込み中の二度押しは二重に読まない")
    func doubleOpenLoadsOnce() async {
        let fake = Self.fake()
        let counter = PresentCounter()
        let model = Self.makeModel(fake, counter: counter)
        async let first: Void = model.openPromptEditor()
        async let second: Void = model.openPromptEditor()
        _ = await (first, second)
        #expect(fake.promptSourcesCount == 1)
        #expect(model.promptEditor != nil)
    }

    @Test("窓を閉じたら下書きを捨て、次に開くと読み直す")
    func closeDiscardsDrafts() async {
        let fake = Self.fake()
        let model = Self.makeModel(fake, counter: PresentCounter())
        await model.openPromptEditor()
        model.editPrompt("捨てる")
        model.promptEditorDidClose()
        #expect(model.promptEditor == nil)

        await model.openPromptEditor()
        #expect(fake.promptSourcesCount == 2)
        #expect(model.promptEditor?.draft(.analyze) == "既定A")
    }

    // MARK: - LiveServices（一時ディレクトリ）

    /// resources/prompts に 4 つのファイルを書く
    static func writePrompts(_ resources: URL) throws {
        let dir = resources.appendingPathComponent("prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = [
            ("analyze_ja.txt", "既定A"), ("map_ja.txt", "既定M"), ("reduce_ja.txt", "既定R"),
            ("repair_json_ja.txt", "修復"),
        ]
        for (name, text) in files {
            try Data(text.utf8).write(to: dir.appendingPathComponent(name))
        }
    }

    /// config.json のファイルに書かれた llm.analysis.prompts
    static func promptsInFile(_ layout: HomeLayout) throws -> [String: Any]? {
        let data = try Data(contentsOf: layout.configFile)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let llm = object?["llm"] as? [String: Any]
        let analysis = llm?["analysis"] as? [String: Any]
        return analysis?["prompts"] as? [String: Any]
    }

    @Test("LiveServices: 保存すると config.json に本文を書き、既定に戻すと null を書く")
    func liveRoundTrip() async throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let (services, layout) = try await AppModelDiarizationTests.liveWithDefaults(tmp)
        try Self.writePrompts(tmp.url)
        let model = Self.makeModel(services, counter: PresentCounter())

        await model.openPromptEditor()
        #expect(model.promptEditor?.draft(.analyze) == "既定A")
        model.editPrompt(Self.valid)
        await model.savePrompts()
        #expect(model.promptEditorError == nil)
        #expect(try Self.promptsInFile(layout)?["analyze"] as? String == Self.valid)
        #expect(try Self.promptsInFile(layout)?["map"] is NSNull)

        model.resetPromptToDefault()
        await model.savePrompts()
        #expect(try Self.promptsInFile(layout)?["analyze"] is NSNull)
    }

    @Test("LiveServices: CV-60 に反する本文は書かない")
    func liveRejectsInvalid() async throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let (services, layout) = try await AppModelDiarizationTests.liveWithDefaults(tmp)
        try Self.writePrompts(tmp.url)
        let model = Self.makeModel(services, counter: PresentCounter())

        await model.openPromptEditor()
        model.editPrompt("指示だけ")
        await model.savePrompts()
        #expect(
            model.promptEditorError
                == "設定に書けませんでした: CV-60  CONFIG_INVALID_VALUE  llm.analysis.prompts.analyze: {schema_block} を含むこと")
        #expect(try Self.promptsInFile(layout)?["analyze"] is NSNull)
    }

    @Test("LiveServices: 同梱のプロンプトが無ければ nil（TEST-28）")
    func liveWithoutPromptFiles() async throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let (services, _) = try await AppModelDiarizationTests.liveWithDefaults(tmp)
        #expect(await services.promptSources() == nil)
    }
}
