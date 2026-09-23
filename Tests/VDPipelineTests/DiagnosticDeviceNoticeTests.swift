// DR-11 と F-81 の unavailable の理由語（mount_failed・not_included）（PLAN §8.11・F-81・issue #119）。
import Foundation
import TestSupport
import Testing
import VDCore
import VDDevice

@testable import VDPipeline

@Suite("DR-11 と F-81 の理由語")
struct DiagnosticDeviceNoticeTests {
    @Test("DR-11 再マウントでアンマウントされたまま（mount_failed）なら、0 台でも ok にせず挿し直しを案内する notice（F-81）")
    func dr11MountFailedIsNotice() async throws {
        let w = try await DiagnosticsWorld.make()
        let s = DiagnosticsWorld.snapshot(unavailable: ["DJIMIC3": "mount_failed"])
        let r = await DiagnosticChecks.dr11(w.context(snapshot: s))
        #expect(r.status == .notice)
        #expect(
            r.details == ["DJIMIC3 は読み取り専用への切り替えの途中でアンマウントされたままです。取り外して、もう一度つなぎ直してください"])
    }

    @Test("DR-11 列挙できないものがあれば fail を優先し、mount_failed の notice にしない（F-81）")
    func dr11NotListableWinsOverMountFailed() async throws {
        let w = try await DiagnosticsWorld.make()
        let s = DiagnosticsWorld.snapshot(
            unavailable: ["DJIMIC3": "mount_failed", "X": "not_listable"], errnos: ["X": EPERM])
        let r = await DiagnosticChecks.dr11(w.context(snapshot: s))
        #expect(r.status == .fail)
        #expect(r.details.first == "X を列挙できません（errno 1）")
    }

    @Test("DR-11 名前が設定に無い録音のボリューム（not_included）だけなら、従来どおり未接続の skip（案内は「はじめに」の⑤。F-81）")
    func dr11NotIncludedOnlyIsNoDevice() async throws {
        let w = try await DiagnosticsWorld.make()
        let s = DiagnosticsWorld.snapshot(unavailable: ["BACKUP": "not_included"])
        let r = await DiagnosticChecks.dr11(w.context(snapshot: s))
        #expect(r.status == .skip)
        #expect(r.details == ["デバイスが接続されていません"])
    }

    @Test("DR-11 デバイスが在り not_included も在れば、台数だけを出して ok（F-81）")
    func dr11NotIncludedWithDeviceIsOK() async throws {
        let w = try await DiagnosticsWorld.make()
        let s = DiagnosticsWorld.snapshot(devices: ["DJIMIC3": true], unavailable: ["BACKUP": "not_included"])
        let r = await DiagnosticChecks.dr11(w.context(snapshot: s))
        #expect(r.status == .ok)
        #expect(r.details == ["1 台を列挙できました"])
    }
}
