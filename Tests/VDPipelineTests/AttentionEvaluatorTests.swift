// 要対応（AttentionEvaluator）のテスト（T-32 §5.6）。沈黙の判定（#117）を含む。
import Darwin
import Foundation
import TestSupport
import Testing
import VDCore
import VDDevice
import VDNotes

@testable import VDPipeline

@Suite("AttentionEvaluator")
struct AttentionEvaluatorTests {
    static let now = Instant(epochMillis: 1_788_040_812_000)

    /// 設定が読めている入力
    static func input() -> AttentionInput {
        var i = AttentionInput(now: now)
        i.configPresent = true
        return i
    }

    /// 1 台つながった snapshot（completedAt は now の secondsAgo 秒前）
    static func snapshot(secondsAgo: Int64, devices: [String] = ["DJIMIC3"]) -> DeviceSnapshot {
        FakeIngest.snapshot(
            completedAt: now.adding(milliseconds: -secondsAgo * 1000),
            devices: Dictionary(uniqueKeysWithValues: devices.map { ($0, Set<String>()) }))
    }

    static func unavailable(_ u: [String: String]) -> DeviceSnapshot {
        DeviceSnapshot(
            generation: 1, completedAt: now, connectEpoch: 0, devices: [:], unavailable: u, notListableErrno: [:])
    }

    static func violation(_ rule: String) -> ConfigViolation {
        ConfigViolation(rule: rule, code: .configInvalidValue, keyPath: "cleanup.deleteSourceAudio", message: "x")
    }

    @Test("TEST-28 何も無ければ 0 件")
    func emptyInputHasNoItems() {
        #expect(AttentionEvaluator.items(Self.input()) == [])
    }

    @Test("設定が読めなければ configInvalid")
    func configInvalid() {
        let items = AttentionEvaluator.items(AttentionInput(now: Self.now))
        #expect(items == [.configInvalid])
        #expect(items.first?.actions == [.revealConfig, .reloadConfig])
    }

    @Test("Vault 未設定のガードから vaultNotConfigured")
    func vaultNotConfiguredFromPause() {
        var i = Self.input()
        i.paused = [.vaultNotConfigured]
        let items = AttentionEvaluator.items(i)
        #expect(items == [.vaultNotConfigured])
        #expect(items.first?.actions == [.chooseVault])
    }

    @Test("vaultUnavailable は VaultStatus を運ぶ")
    func vaultUnavailableCarriesStatus() {
        var i = Self.input()
        i.paused = [.vaultUnavailable]
        i.vault = .missingMarker
        let items = AttentionEvaluator.items(i)
        #expect(items == [.vaultUnavailable(.missingMarker)])
        #expect(items.first?.actions == [.chooseVault])
    }

    @Test("EPERM ならシステム設定の操作も出す")
    func vaultEPERMOffersSystemSettings() {
        var i = Self.input()
        i.paused = [.vaultUnavailable]
        i.vault = .notReadable(errno: EPERM)
        #expect(AttentionEvaluator.items(i).first?.actions == [.chooseVault, .openSystemSettings])
    }

    @Test("モデルの理由は種類ごと")
    func modelMissingPerKind() {
        var i = Self.input()
        i.paused = [.llmModelMissing, .vadModelMissing, .modelMissing]
        #expect(AttentionEvaluator.items(i) == [.modelMissing(.whisper), .modelMissing(.vad), .modelMissing(.llm)])
    }

    @Test("LLM の未選択とメモリ不足")
    func llmNotSelectedAndMemory() {
        var i = Self.input()
        i.paused = [.llmNotSelected, .llmInsufficientMemory]
        let items = AttentionEvaluator.items(i)
        #expect(items == [.llmNotSelected, .llmInsufficientMemory])
        #expect(items.map(\.actions) == [[.openModels], [.openModels]])
    }

    @Test("whisper-cli と llama-server が無い")
    func toolMissing() {
        var i = Self.input()
        i.paused = [.whisperMissing, .llamaServerMissing]
        let items = AttentionEvaluator.items(i)
        #expect(items == [.toolMissing(.whisperCLI), .toolMissing(.llamaServer)])
        #expect(items.map(\.actions) == [[.runDiagnostics], [.runDiagnostics]])
    }

    @Test("license は要対応にしない")
    func licenseIsNotAnAttention() {
        var i = Self.input()
        i.paused = [.license]
        #expect(AttentionEvaluator.items(i) == [])
    }

    @Test("使えないデバイスは理由ごとに、名前はバイト順")
    func deviceUnavailableReasonsSplit() {
        var i = Self.input()
        i.snapshot = Self.unavailable(["B": "not_listable", "A": "mount_name_mismatch", "C": "invalid_device_id"])
        let items = AttentionEvaluator.items(i)
        #expect(items == [.deviceNotListable("B"), .deviceNeedsReplug("A"), .deviceNameInvalid("C")])
        #expect(items.map(\.actions) == [[.openSystemSettings], [], []])
    }

    @Test("ほかの理由は出さない")
    func unknownUnavailableReasonIsIgnored() {
        var i = Self.input()
        i.snapshot = Self.unavailable(["X": "no_recordings"])
        #expect(AttentionEvaluator.items(i) == [])
    }

    @Test("沈黙: 接続中・走査していない・古い")
    func silentWhenStale() {
        var i = Self.input()
        i.snapshot = Self.snapshot(secondsAgo: 901)
        #expect(AttentionEvaluator.items(i).contains(.ingestSilent))
        #expect(AttentionEvaluator.isIngestSilent(i))
    }

    @Test("#117 走査中は誤報しない")
    func notSilentWhileScanning() {
        var i = Self.input()
        i.snapshot = Self.snapshot(secondsAgo: 901)
        i.ingestActivity = IngestActivity(scanning: true, deviceID: "DJIMIC3", copied: 0, total: 0, lastActivityAt: nil)
        #expect(!AttentionEvaluator.items(i).contains(.ingestSilent))
    }

    @Test("#117 コピー中は誤報しない")
    func notSilentWhileCopying() {
        var i = Self.input()
        i.snapshot = Self.snapshot(secondsAgo: 3600)
        i.ingestActivity = IngestActivity(
            scanning: false, deviceID: "DJIMIC3", copied: 3, total: 9,
            lastActivityAt: Self.now.adding(milliseconds: -10_000))
        #expect(!AttentionEvaluator.items(i).contains(.ingestSilent))
    }

    @Test("ちょうどは沈黙ではない")
    func notSilentAtExactlyMaxAge() {
        var i = Self.input()
        i.snapshot = Self.snapshot(secondsAgo: 900)
        #expect(!AttentionEvaluator.items(i).contains(.ingestSilent))
    }

    @Test("0 台なら沈黙ではない")
    func notSilentWithoutDevice() {
        var i = Self.input()
        i.snapshot = Self.snapshot(secondsAgo: 3600, devices: [])
        #expect(!AttentionEvaluator.items(i).contains(.ingestSilent))
    }

    @Test("まだ走査していなければ沈黙ではない")
    func notSilentWithoutSnapshot() {
        var i = Self.input()
        i.snapshot = nil
        #expect(!AttentionEvaluator.isIngestSilent(i))
    }

    @Test("空き容量のガードから diskSpaceLow")
    func diskSpaceLow() {
        var i = Self.input()
        i.paused = [.diskSpaceLow]
        #expect(AttentionEvaluator.items(i) == [.diskSpaceLow])
    }

    @Test("CV-30 なら lockMismatch")
    func lockMismatchFromCV30() {
        var i = Self.input()
        i.violations = [Self.violation("CV-30")]
        #expect(AttentionEvaluator.items(i).contains(.lockMismatch))
    }

    @Test("CV-33 なら lockMismatch")
    func lockMismatchFromCV33() {
        var i = Self.input()
        i.violations = [Self.violation("CV-33")]
        #expect(AttentionEvaluator.items(i).contains(.lockMismatch))
    }

    @Test("ほかの規則では lockMismatch にしない")
    func noLockMismatchForOtherRules() {
        var i = Self.input()
        i.violations = [Self.violation("CV-01")]
        #expect(!AttentionEvaluator.items(i).contains(.lockMismatch))
    }

    @Test("reaper の版が違えば更新を求める")
    func reaperUpdateRequired() {
        var i = Self.input()
        // 削除が有効な間だけ（F-80）
        i.deletionEnabled = true
        i.reaper = .versionMismatch(found: "0.9.0")
        let items = AttentionEvaluator.items(i)
        #expect(items == [.reaperUpdateRequired])
        #expect(items.first?.actions == [.openDeletionFlow])
    }

    @Test("reaper が有効なら何も出さない")
    func reaperValidIsQuiet() {
        var i = Self.input()
        i.reaper = .valid(version: "1.0.0")
        #expect(!AttentionEvaluator.items(i).contains(.reaperUpdateRequired))
    }

    @Test("並びは §8.11 の表の順")
    func orderFollowsTheSpecTable() {
        // 設定エラー中は停止理由から作る項目を出さない（F-80）ので、設定が読めている入力で全部を並べる（configInvalid の順は order が固定する）
        var i = Self.input()
        i.paused = PauseReason.allCases
        i.vault = .missingRoot
        i.snapshot = DeviceSnapshot(
            generation: 1, completedAt: Self.now.adding(milliseconds: -3_600_000), connectEpoch: 0,
            devices: [
                "DJIMIC3": DeviceObservation(
                    deviceID: "DJIMIC3", mountPath: "/tmp/vd-fake/DJIMIC3", deviceNode: nil, readOnly: false,
                    freeBytes: nil, relpaths: [])
            ],
            unavailable: ["B": "not_listable", "A": "mount_name_mismatch", "C": "invalid_device_id"],
            notListableErrno: [:])
        i.violations = [Self.violation("CV-30")]
        i.reaper = .versionMismatch(found: nil)
        i.deletionEnabled = true
        i.undeletableSources = 2
        i.rawNoteBlocked = 1
        let items = AttentionEvaluator.items(i)
        #expect(items.count == 18)
        #expect(items.map(\.order) == items.map(\.order).sorted())
        #expect(items.first == .vaultNotConfigured)
        #expect(items.last == .rawNoteBlocked(1))
    }

    @Test("FAILED は要対応にしない（F-75 の本文を守って止めた Session の数だけは別の項目）")
    func failedPartsAreNotAttention() {
        // AttentionInput に FAILED の Part を渡す口は無い（型で保証）。F-75 の rawNoteBlocked は Session の数だけを受ける。
        // 全ケースを 1 つずつ並べ、件数と順を固定する
        let all: [AttentionItem] = [
            .configInvalid, .vaultNotConfigured, .vaultUnavailable(.missingRoot), .modelMissing(.whisper),
            .llmNotSelected, .llmInsufficientMemory, .toolMissing(.whisperCLI), .deviceNotListable("A"),
            .deviceNeedsReplug("A"), .deviceNameInvalid("A"), .ingestSilent, .diskSpaceLow, .lockMismatch,
            .reaperUpdateRequired, .undeletableSources(1), .rawNoteBlocked(1),
        ]
        for item in all {
            // 網羅の switch（ケースが増えたらここがコンパイルで落ちる）
            switch item {
            case .configInvalid, .vaultNotConfigured, .vaultUnavailable, .modelMissing, .llmNotSelected,
                .llmInsufficientMemory, .toolMissing, .deviceNotListable, .deviceNeedsReplug, .deviceNameInvalid,
                .ingestSilent, .diskSpaceLow, .lockMismatch, .reaperUpdateRequired, .undeletableSources,
                .rawNoteBlocked:
                break
            }
        }
        #expect(all.count == 16)
        #expect(all.map(\.order) == Array(0..<16))
    }
}
