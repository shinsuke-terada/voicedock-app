// 「はじめに」の 5 項目（OnboardingEvaluator）のテスト（T-31 §5.2）。
import Foundation
import Testing
import VDCore
import VDDevice
import VDNotes

@testable import VoiceDockApp

@Suite("Onboarding")
struct OnboardingTests {
    static let fixed = Instant(epochMillis: 1_756_000_000_000)

    static func item(_ s: AppSnapshot, _ step: OnboardingStep) throws -> OnboardingItem {
        try #require(OnboardingEvaluator.items(s).first { $0.step == step })
    }

    static func observation(_ id: String) -> DeviceObservation {
        DeviceObservation(
            deviceID: id, mountPath: "/tmp/voicedock-t31/" + id, deviceNode: nil, readOnly: true, freeBytes: nil,
            relpaths: [])
    }

    static func deviceSnapshot(devices: [String], unavailable: [String: String]) -> DeviceSnapshot {
        DeviceSnapshot(
            generation: 1, completedAt: fixed, connectEpoch: 1,
            devices: Dictionary(uniqueKeysWithValues: devices.map { ($0, observation($0)) }), unavailable: unavailable,
            notListableErrno: [:])
    }

    @Test("5 項目は PLAN の ①〜⑤ の順")
    func orderIsTheSpecOrder() {
        let items = OnboardingEvaluator.items(AppSnapshot(now: Self.fixed))
        #expect(items.map(\.step) == [.vault, .whisperModel, .llmModel, .loginItem, .deviceName])
        #expect(
            items.map(\.title) == [
                "Vault を選ぶ", "Whisper モデルを入手する", "LLM を選んで入手する", "ログイン時に起動する", "デバイスの名前を変える",
            ])
    }

    @Test("Vault は .available で完了")
    func vaultDoneWhenAvailable() throws {
        var s = AppSnapshot(now: Self.fixed)
        s.vault = .available
        #expect(try Self.item(s, .vault).done)
    }

    @Test("目印が無ければ未完了")
    func vaultNotDoneWhenMarkerMissing() throws {
        var s = AppSnapshot(now: Self.fixed)
        s.vault = .missingMarker
        #expect(try Self.item(s, .vault).done == false)
    }

    @Test("VAD 有効なら VAD も要る")
    func whisperDoneNeedsVADWhenEnabled() throws {
        var s = AppSnapshot(now: Self.fixed)
        s.whisperPresent = true
        s.vadEnabled = true
        s.vadPresent = false
        #expect(try Self.item(s, .whisperModel).done == false)
    }

    @Test("VAD 無効なら Whisper だけで完了")
    func whisperDoneWithoutVADWhenDisabled() throws {
        var s = AppSnapshot(now: Self.fixed)
        s.whisperPresent = true
        s.vadEnabled = false
        s.vadPresent = false
        #expect(try Self.item(s, .whisperModel).done)
    }

    @Test("LLM は選択と入手の両方")
    func llmNeedsSelectionAndFile() throws {
        var selectedOnly = AppSnapshot(now: Self.fixed)
        selectedOnly.llmModelID = "a"
        selectedOnly.llmPresent = false
        var presentOnly = AppSnapshot(now: Self.fixed)
        presentOnly.llmModelID = nil
        presentOnly.llmPresent = true
        #expect(try Self.item(selectedOnly, .llmModel).done == false)
        #expect(try Self.item(presentOnly, .llmModel).done == false)
    }

    @Test("オンなら完了")
    func loginItemDoneWhenEnabled() throws {
        var s = AppSnapshot(now: Self.fixed)
        s.loginItem = .enabled
        #expect(try Self.item(s, .loginItem).done)
    }

    @Test("今はしないでも完了")
    func loginItemDoneWhenDecided() throws {
        var s = AppSnapshot(now: Self.fixed)
        s.loginItem = .notRegistered
        s.uiState.loginItemDecided = true
        #expect(try Self.item(s, .loginItem).done)
    }

    @Test("改名が要らなければ出さない")
    func deviceNameHiddenWithoutCandidates() throws {
        var s = AppSnapshot(now: Self.fixed)
        s.renameCandidates = []
        #expect(try Self.item(s, .deviceName).visible == false)
    }

    @Test("⑤ は完了にならない")
    func deviceNameNeverDone() throws {
        var s = AppSnapshot(now: Self.fixed)
        s.renameCandidates = ["NO NAME"]
        let item = try Self.item(s, .deviceName)
        #expect(item.visible == true)
        #expect(item.done == false)
        #expect(item.detail?.hasPrefix("NO NAME という名前のデバイスがつながっています。") == true)
    }

    @Test("devices と unavailable の両方から集める")
    func renameCandidatesFromBothMaps() {
        let both = Self.deviceSnapshot(devices: ["NO NAME"], unavailable: ["NO NAME": "invalid_device_id"])
        let unavailableOnly = Self.deviceSnapshot(devices: [], unavailable: ["NO NAME": "mount_name_mismatch"])
        #expect(OnboardingEvaluator.renameCandidates(both) == ["NO NAME"])
        #expect(OnboardingEvaluator.renameCandidates(unavailableOnly) == ["NO NAME"])
    }

    @Test("NO NAME 以外は案内しない")
    func renameCandidatesIgnoreOtherNames() {
        let s = Self.deviceSnapshot(devices: ["DJIMIC3"], unavailable: [:])
        #expect(OnboardingEvaluator.renameCandidates(s) == [])
    }

    @Test("全部終われば節を出さない")
    func completeWhenAllDone() {
        var s = AppSnapshot(now: Self.fixed)
        s.vault = .available
        s.whisperPresent = true
        s.vadEnabled = true
        s.vadPresent = true
        s.llmModelID = "test-llm"
        s.llmPresent = true
        s.loginItem = .enabled
        s.renameCandidates = []
        #expect(OnboardingEvaluator.isComplete(s) == true)
    }

    @Test("TEST-28 何も無い観測")
    func emptySnapshotShowsFourItems() {
        let s = AppSnapshot(now: Self.fixed)
        let visible = OnboardingEvaluator.items(s).filter(\.visible)
        #expect(visible.count == 4)
        #expect(visible.allSatisfy { !$0.done })
        #expect(OnboardingEvaluator.isComplete(s) == false)
        #expect(OnboardingEvaluator.renameCandidates(nil) == [])
    }
}
