// AppModel のログイン項目と「今はしない」のテスト（T-31 §5.6）。SMAppService には触れない（services は偽物）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore

@testable import VoiceDockApp

@MainActor
@Suite("AppModel のログイン項目")
struct AppModelLoginItemTests {
    static let fixed = Instant(epochMillis: 1_756_000_000_000)
    static let layout = HomeLayout(root: URL(fileURLWithPath: "/tmp/voicedock-t31-layout", isDirectory: true))

    static func present() -> AppSnapshot {
        var s = AppSnapshot(now: fixed)
        s.configPresent = true
        s.loginItem = .notRegistered
        return s
    }

    static func makeModel(_ fake: FakeServices) -> AppModel {
        AppModel(
            services: fake, openFinder: FakeFinder(), layout: layout, catalog: TestCatalogs.minimal,
            chooser: FakeFolderChooser(nil), fileChooser: FakeFileChooser(nil), presentModal: { $0() },
            sleeper: RecordingSleeper(), now: fixed, quit: {})
    }

    @Test("オンで register")
    func turningOnRegisters() async {
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake)
        await model.setLoginItem(true)
        #expect(fake.registerCount == 1)
        #expect(fake.unregisterCount == 0)
    }

    @Test("オフで unregister")
    func turningOffUnregisters() async {
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake)
        await model.setLoginItem(false)
        #expect(fake.unregisterCount == 1)
        #expect(fake.registerCount == 0)
    }

    @Test("オンにしたら『はじめに』も完了にする")
    func turningOnMarksDecided() async {
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake)
        await model.setLoginItem(true)
        #expect(fake.savedStates == [UIState(schema: 1, loginItemDecided: true)])
    }

    @Test("今はしないは登録しない")
    func laterMarksDecidedWithoutRegistering() async {
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake)
        await model.dismissLoginItem()
        #expect(fake.savedStates.count == 1)
        #expect(fake.savedStates.first?.loginItemDecided == true)
        #expect(fake.registerCount == 0)
    }

    @Test("失敗の文言をそのまま出す")
    func registerFailureIsShown() async {
        let fake = FakeServices(Self.present())
        fake.setRegister(.failure("Operation not permitted"))
        let model = Self.makeModel(fake)
        await model.setLoginItem(true)
        #expect(model.loginItemError == "Operation not permitted")
        #expect(fake.savedStates.isEmpty)
    }

    @Test("記録できなければ知らせる")
    func saveFailureIsShown() async {
        let fake = FakeServices(Self.present())
        fake.setSaveResult(false)
        let model = Self.makeModel(fake)
        await model.dismissLoginItem()
        #expect(model.uiStateSaveFailed == true)
    }

    @Test("システム設定を開く")
    func openSettingsIsForwarded() {
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake)
        model.openLoginItemSettings()
        #expect(fake.openSettingsCount == 1)
    }

    @Test("承認待ちはエラーにしない")
    func requiresApprovalIsNotAnError() async {
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake)
        // register は成功し、その後の観測が承認待ち
        var after = Self.present()
        after.loginItem = .requiresApproval
        fake.set(after)
        await model.setLoginItem(true)
        #expect(model.loginItemError == nil)
        #expect(model.snapshot.loginItem == .requiresApproval)
    }
}
