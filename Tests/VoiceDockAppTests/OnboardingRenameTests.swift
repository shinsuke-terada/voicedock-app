// 「はじめに」の⑤（改名の案内）を、既定の include（["DJIMIC3"]）に合わない録音のボリュームにも出す（PLAN §8.12・F-81・issue #119）。
import Foundation
import TestSupport
import Testing
import VDCore
import VDDevice

@testable import VoiceDockApp

@Suite("「はじめに」の⑤ 改名の案内（F-81）")
struct OnboardingRenameTests {
    static func snapshot(devices: [String] = [], unavailable: [String: String]) -> DeviceSnapshot {
        OnboardingTests.deviceSnapshot(devices: devices, unavailable: unavailable)
    }

    @Test("F-81 名前が include に合わない録音のボリューム（unavailable の not_included）を改名の候補にする")
    func notIncludedVolumesAreCandidates() {
        let s = Self.snapshot(
            devices: ["DJIMIC3"],
            unavailable: ["NO NAME": "not_included", "DJIMIC3 1": "not_included", "MYMIC": "not_included"])
        #expect(OnboardingEvaluator.renameCandidates(s) == ["DJIMIC3 1", "MYMIC", "NO NAME"])
    }

    @Test("F-81 include が空の旧い設定で検出された NO NAME も従来どおり候補にし、重ねない")
    func factoryNameStillCounted() {
        let s = Self.snapshot(devices: ["NO NAME"], unavailable: ["NO NAME": "not_included"])
        #expect(OnboardingEvaluator.renameCandidates(s) == ["NO NAME"])
    }

    @Test("F-81 not_included 以外の理由（not_listable・mount_failed など）の名前は候補にしない")
    func otherReasonsAreNotCandidates() {
        let s = Self.snapshot(
            unavailable: [
                "DJIMIC3": "mount_failed", "DJIMIC4": "not_listable", "DJIMIC5": "mount_name_mismatch",
                "DJI:MIC": "invalid_device_id",
            ])
        #expect(OnboardingEvaluator.renameCandidates(s) == [])
    }

    @Test("F-81 unavailable も devices も空なら候補は無く⑤は出ない（TEST-28）")
    func emptySnapshotHasNoCandidates() throws {
        #expect(OnboardingEvaluator.renameCandidates(Self.snapshot(unavailable: [:])) == [])
        var app = AppSnapshot(now: OnboardingTests.fixed)
        app.renameCandidates = OnboardingEvaluator.renameCandidates(Self.snapshot(unavailable: [:]))
        #expect(try OnboardingTests.item(app, .deviceName).visible == false)
    }

    @Test("F-81 ⑤の案内は既定の include と食い違わない（DJIMIC3 に変えるか、device.includeVolumes に名前を足す）")
    func instructionsMatchDefaultInclude() throws {
        var app = AppSnapshot(now: OnboardingTests.fixed)
        app.renameCandidates = OnboardingEvaluator.renameCandidates(
            Self.snapshot(unavailable: ["BACKUP": "not_included"]))
        let item = try OnboardingTests.item(app, .deviceName)
        #expect(item.visible == true)
        #expect(item.done == false)
        #expect(
            item.detail
                == "BACKUP という名前のデバイスがつながっています。VoiceDock が取り込むのは、名前が設定の device.includeVolumes"
                + "（既定は DJIMIC3 だけ。空なら全部）に合うデバイスです。VoiceDock はデバイスに一切書き込みません。"
                + "DJI Mic 3 なら、次のどちらかを利用者が行ってください。\n"
                + "1. Finder のサイドバーでデバイスを選び、名前をゆっくり 2 回クリックして「DJIMIC3」に変えます。"
                + "変えたらデバイスを取り外して、もう一度つなぎ直してください\n"
                + "2. 名前を変えずに使うなら、config.json の device.includeVolumes にこの名前を足して、「設定を読み直す」を押してください\n"
                + "名前が「DJIMIC3 1」のように番号付きなら、名前は変えずに取り外して、もう一度つなぎ直してください。"
                + "録音の写しを入れたメモリなど DJI Mic 3 でなければ、何もしなくてかまいません（取り込みも削除もしません）")
        #expect(item.detail?.contains("などに変えます") == false)
    }
}
