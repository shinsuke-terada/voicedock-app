// AppModel の Vault の選択（chooseVault）のテスト（T-31 §5.4）。chooser・services・presentModal はすべて偽物。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore

@testable import VoiceDockApp

@MainActor
@Suite("AppModel の Vault")
struct AppModelVaultTests {
    static let fixed = Instant(epochMillis: 1_756_000_000_000)
    static let layout = HomeLayout(root: URL(fileURLWithPath: "/tmp/voicedock-t31-layout", isDirectory: true))

    /// presentModal が呼ばれた回数と、その中で chooser が呼ばれたか
    final class ModalRecorder {
        var calls = 0
        var chooserCallsInside = 0
    }

    static func present() -> AppSnapshot {
        var s = AppSnapshot(now: fixed)
        s.configPresent = true
        return s
    }

    static func makeModel(
        _ fake: FakeServices, chooser: FakeFolderChooser, recorder: ModalRecorder = ModalRecorder()
    ) -> AppModel {
        AppModel(
            services: fake, openFinder: FakeFinder(), layout: layout, catalog: TestCatalogs.minimal, chooser: chooser,
            fileChooser: FakeFileChooser(nil),
            presentModal: { body in
                recorder.calls += 1
                let before = chooser.calls
                let result = body()
                recorder.chooserCallsInside += chooser.calls - before
                return result
            },
            sleeper: RecordingSleeper(), now: fixed, quit: {})
    }

    /// TempDirectory の下に Vault のフォルダを作る（withMarker なら .obsidian/ も）。末尾の / の無いパスを返す
    static func makeVault(_ tmp: TempDirectory, withMarker: Bool) throws -> String {
        let dir = tmp.url.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if withMarker {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(".obsidian", isDirectory: true), withIntermediateDirectories: true)
        }
        return tmp.url.path(percentEncoded: false) + "Vault"
    }

    static func url(_ path: String) -> URL { URL(filePath: path, directoryHint: .notDirectory) }

    @Test("取り消したら何もしない")
    func cancelChangesNothing() async {
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake, chooser: FakeFolderChooser(nil))
        await model.chooseVault()
        #expect(fake.updatedConfigs.isEmpty)
        #expect(model.vaultError == nil)
        #expect(fake.scanCount == 0)
    }

    @Test("目印が無いフォルダは拒否する")
    func rejectsFolderWithoutMarker() async throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let path = try Self.makeVault(tmp, withMarker: false)
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake, chooser: FakeFolderChooser(Self.url(path)))
        await model.chooseVault()
        #expect(fake.updatedConfigs.isEmpty)
        #expect(model.vaultError == path + " に .obsidian/ がありません（Vault が未マウントか、別の場所を指しています）")
    }

    @Test("読めないフォルダは拒否する")
    func rejectsUnreadableFolder() async throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let path = try Self.makeVault(tmp, withMarker: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake, chooser: FakeFolderChooser(Self.url(path)))
        await model.chooseVault()
        #expect(model.vaultError?.contains("を読めません（errno ") == true)
        #expect(fake.updatedConfigs.isEmpty)
    }

    @Test("目印が在れば設定に書く")
    func acceptsVaultAndWritesConfig() async throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let path = try Self.makeVault(tmp, withMarker: true)
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake, chooser: FakeFolderChooser(Self.url(path)))
        await model.chooseVault()
        #expect(fake.updatedConfigs.count == 1)
        #expect(fake.updatedConfigs.first?.vault.path == path)
        #expect(model.vaultError == nil)
    }

    @Test("選んだら走査を促す")
    func scansAfterChoosing() async throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let path = try Self.makeVault(tmp, withMarker: true)
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake, chooser: FakeFolderChooser(Self.url(path)))
        await model.chooseVault()
        #expect(fake.scanCount == 1)
    }

    @Test("設定に弾かれたら文言を出す")
    func configRejectionIsShown() async throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let path = try Self.makeVault(tmp, withMarker: true)
        let fake = FakeServices(Self.present())
        let v = ConfigViolation(rule: "CV-40", code: .configInvalidValue, keyPath: "vault.path", message: "x")
        fake.setUpdateViolations([v])
        let model = Self.makeModel(fake, chooser: FakeFolderChooser(Self.url(path)))
        await model.chooseVault()
        #expect(model.vaultError?.hasPrefix("設定に書けませんでした: ") == true)
        #expect(fake.scanCount == 0)
    }

    @Test("閉じたら消える")
    func closingClearsMessages() async throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let path = try Self.makeVault(tmp, withMarker: false)
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake, chooser: FakeFolderChooser(Self.url(path)))
        await model.chooseVault()
        #expect(model.vaultError != nil)
        model.panelDidClose()
        #expect(model.vaultError == nil)
    }

    @Test("popover を閉じてから開き直す")
    func modalIsWrapped() async {
        let fake = FakeServices(Self.present())
        let chooser = FakeFolderChooser(nil)
        let recorder = ModalRecorder()
        let model = Self.makeModel(fake, chooser: chooser, recorder: recorder)
        await model.chooseVault()
        #expect(recorder.calls == 1)
        #expect(recorder.chooserCallsInside == 1)
        #expect(chooser.calls == 1)
    }
}
