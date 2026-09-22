// 層 A の ND: アプリが削除条件を偽にすること（PLAN 付録 B.1・§10.5。T-36 §6.1）。
// 舞台は三重ロックを全部外した DeletionScene。各テストは弾かせたい条件以外をすべて満たす（TEST-19）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDStore

@testable import VDPipeline

@Suite("DeletionPolicy の ND（層 A）")
struct DeletionPolicyNDTests {
    /// 今の舞台で評価する（snapshot は既定。candidate は DB から読み直す）
    static func evaluate(_ scene: DeletionScene, snapshot: DeviceSnapshot? = nil) async throws -> (
        DeletionCandidate, DeletionContext
    ) {
        let ctx = await scene.context(snapshot: snapshot ?? scene.snapshot())
        return (try scene.candidate(), ctx)
    }

    @Test("正の対照 [A] 三重ロックを外し本文が 2 か所に在れば削除条件が真")
    func everyTermHoldsWhenEverythingIsValid() async throws {
        let scene = try DeletionScene()
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.canDeleteSource(c, ctx))
        #expect(DeletionPolicy.deletionIsIdentified(c, ctx))
        #expect(DeletionPolicy.textIsPreserved(c.part, c.session, c.parts, ctx))
        #expect(DeletionPolicy.preIdentityCheck(c.part, ctx))
        #expect(DeletionPolicy.partTranscriptIsValid(c.part, ctx))
        #expect(DeletionPolicy.verifyRawNote(c.session, c.parts, ctx) == .passed)
        #expect(DeletionPolicy.frontmatterKeys(c.session.rawOutputPath, ctx).contains(DeletionScene.partkey))
        #expect(ctx.locks.readiness == .configured)
        #expect(DeletionPolicy.nothingToPreserve(c, ctx) == false)
    }

    /// 状態だけを壊した舞台: 削除条件は偽、同定と Raw ノートの検証は通る
    static func expectOnlyStatusBlocks(_ scene: DeletionScene) async throws {
        let (c, ctx) = try await evaluate(scene)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
        #expect(DeletionPolicy.deletionIsIdentified(c, ctx))
        #expect(DeletionPolicy.verifyRawNote(c.session, c.parts, ctx) == .passed)
    }

    @Test("ND-01 [A] 変換中（NORMALIZING）の Part は消さない")
    func nd01PartStillNormalizing() async throws {
        try await Self.expectOnlyStatusBlocks(try DeletionScene(status: .normalizing))
    }

    @Test("ND-02 [A] 変換結果の長さがずれて FAILED の Part は消さない")
    func nd02NormalizeVerifyFailed() async throws {
        try await Self.expectOnlyStatusBlocks(try DeletionScene(status: .failed, errorCode: .normalizeVerifyFailed))
    }

    @Test("ND-03 [A] 重複は deleteSkippedSource が偽なら消さない")
    func nd03DuplicateKeptWhileLockBIsClosed() async throws {
        let scene = try DeletionScene()
        let dup = try scene.addPart(
            fileName: "TX00_MIC002_20260912_093000_orig.wav", startedAt: "2026-09-12T09:30:00+09:00",
            status: .skipped, errorCode: .duplicateContent, duplicateOf: DeletionScene.partkey, transcript: false,
            inRawNote: false)
        let ctx = await scene.context(snapshot: scene.snapshot())
        let c = try scene.candidate(dup)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
        // 対照: ロック B を開けると真（twin が引けている）
        scene.updateConfig { $0.cleanup.deleteSkippedSource = true }
        let opened = await scene.context(snapshot: scene.snapshot())
        #expect(c.twin?.part.partkey == DeletionScene.partkey)
        #expect(DeletionPolicy.canDeleteSource(c, opened))
    }

    @Test("ND-04 [A] whisper の失敗で FAILED の Part は消さない")
    func nd04WhisperFailed() async throws {
        let scene = try DeletionScene(status: .failed, errorCode: .whisperFailed)
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
        #expect(DeletionPolicy.deletionIsIdentified(c, ctx))
    }

    @Test("ND-05 [A] whisper のタイムアウトで FAILED の Part は消さない")
    func nd05WhisperTimeout() async throws {
        let scene = try DeletionScene(status: .failed, errorCode: .whisperTimeout)
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
        #expect(DeletionPolicy.deletionIsIdentified(c, ctx))
    }

    @Test("ND-06 [A] 無音は deleteSkippedSource が偽なら消さない")
    func nd06NoSpeechKeptWhileLockBIsClosed() async throws {
        let scene = try DeletionScene(status: .skipped, errorCode: .noSpeechDetected)
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
        // 対照: ロック B を開けると真
        scene.updateConfig { $0.cleanup.deleteSkippedSource = true }
        let opened = await scene.context(snapshot: scene.snapshot())
        #expect(DeletionPolicy.canDeleteSource(c, opened))
    }

    @Test("ND-07 [A] Raw ノートの書き込みに失敗（raw_output_path が NULL）なら消さない")
    func nd07MissingRawNotePath() async throws {
        let scene = try DeletionScene()
        try scene.store.updateSession(DeletionScene.sessionKey, [.rawOutputPath(nil)])
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
        #expect(DeletionPolicy.verifyRawNote(c.session, c.parts, ctx) == .notRecorded)
    }

    @Test("ND-08 [A] 保存後に Raw ノートが消えた・改変されたら消さない（パラメータ化: 削除・追記）", arguments: ["削除", "追記"])
    func nd08RawNoteChangedAfterSaving(_ change: String) async throws {
        let scene = try DeletionScene()
        if change == "削除" {
            try FileManager.default.removeItem(at: try scene.rawNoteURL())
        } else {
            try scene.appendToRawNote("\n追記された行\n")
        }
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
        if change == "削除" {
            #expect(DeletionPolicy.verifyRawNote(c.session, c.parts, ctx) == .failed(["RN-1"]))
        } else {
            #expect(DeletionPolicy.verifyRawNote(c.session, c.parts, ctx) == .failed(["RN-4"]))
            // verifyRawNote を単独で落とす（鍵の包含はまだ真）
            #expect(DeletionPolicy.frontmatterKeys(c.session.rawOutputPath, ctx).contains(DeletionScene.partkey))
        }
    }

    @Test("ND-09 [A] Raw ノートの鍵に当該 Part が無ければ消さない")
    func nd09RawNoteWithoutThisKey() async throws {
        let scene = try DeletionScene()
        try scene.replaceInRawNote(DeletionScene.partkey, with: "DJIMIC3/other/other.wav", updateSHA: true)
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
        #expect(!DeletionPolicy.frontmatterKeys(c.session.rawOutputPath, ctx).contains(DeletionScene.partkey))
    }

    @Test("ND-21 [A] Part 0 件の Session では消さない（番犬）")
    func nd21EmptyPartsIsNotDeletable() async throws {
        let scene = try DeletionScene()
        let (loaded, ctx) = try await Self.evaluate(scene)
        let c = DeletionCandidate(part: loaded.part, session: loaded.session, parts: [], twin: nil)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
        // 番犬だけが落とす（根拠 A は空の Part 集合でも真になる）
        #expect(DeletionPolicy.textIsPreserved(c.part, c.session, [], ctx))
    }

    @Test("ND-21 [A] source_path が nil か空なら消さない（パラメータ化）", arguments: [nil, ""] as [String?])
    func nd21NullOrEmptySourcePath(_ value: String?) async throws {
        let scene = try DeletionScene()
        try StorePaths.setSourcePath(scene.store, partkey: DeletionScene.partkey, value)
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
        #expect(DeletionPolicy.preIdentityCheck(c.part, ctx) == false)
    }

    @Test("ND-22 [A] ロック 1 の片方だけ偽でも消さない（パラメータ化: アプリ・reaper.conf）", arguments: ["アプリ", "reaper.conf"])
    func nd22EitherSideOfLockOneBlocks(_ side: String) async throws {
        let scene = try DeletionScene()
        if side == "アプリ" {
            scene.updateConfig { $0.cleanup.deleteSourceAudio = false }
        } else {
            try scene.writeReaperConf(deleteSourceAudio: false)
        }
        let (c, ctx) = try await Self.evaluate(scene)
        let want = side == "アプリ" ? "delete_source_audio_disabled" : "lock_mismatch"
        #expect(ctx.locks.readiness == .disabled(want))
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
    }

    @Test("ND-23 [A] デバイスが読み取り専用（観測）なら消さない")
    func nd23ReadOnlyObservedBlocks() async throws {
        let scene = try DeletionScene()
        let (c, ctx) = try await Self.evaluate(scene, snapshot: scene.snapshot(readOnly: true))
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
        #expect(ctx.locks.writability("DJIMIC3") == .readOnly)
    }

    @Test("ND-23 [A] 事前確認で開いたボリュームが読み取り専用なら消さない（二重確認）")
    func nd23ReadOnlyVolumeHandleBlocks() async throws {
        let scene = try DeletionScene()
        let ctx = await scene.context(snapshot: scene.snapshot(), opener: FakeVolumeOpener(readOnly: true))
        let c = try scene.candidate()
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
        #expect(DeletionPolicy.deletionIsIdentified(c, ctx) == false)
        #expect(ctx.locks.allReleased(for: c.part.deviceID))
        #expect(DeletionPolicy.preIdentityCheck(c.part, ctx) == false)
    }

    @Test("ND-26 [A] bin/voicedock-reaper が無ければ要求の条件が偽")
    func nd26ReaperNotInstalledBlocks() async throws {
        let scene = try DeletionScene()
        try scene.removeReaper()
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
        #expect(ctx.locks.readiness == .disabled("reaper_not_installed"))
        // 無いものを検証・起動しない
        #expect(scene.verifier.verifiedURLs.isEmpty)
        #expect(await scene.runner.recorded.isEmpty)
    }

    @Test("ND-31 [A] device_id だけが違う鍵では消さない")
    func nd31KeyFromAnotherDeviceBlocks() async throws {
        let scene = try DeletionScene()
        let other = try PartKey.make(deviceID: "NO NAME", relpath: DeletionScene.relpath)
        try scene.replaceInRawNote(DeletionScene.partkey, with: other, updateSHA: true)
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
        let keys = DeletionPolicy.frontmatterKeys(c.session.rawOutputPath, ctx)
        #expect(keys.contains(other))
        #expect(!keys.contains(DeletionScene.partkey))
    }

    @Test(
        "ND-32 [A] Part の transcript が無いか壊れていれば消さない（パラメータ化: 列が NULL・ファイルが無い・JSON が壊れている）",
        arguments: ["列が NULL", "ファイルが無い", "JSON が壊れている"])
    func nd32BrokenPartTranscriptBlocks(_ fault: String) async throws {
        let scene = try DeletionScene()
        let url = scene.transcriptURL(DeletionScene.partkey)
        switch fault {
        case "列が NULL":
            try scene.store.updateRecording(DeletionScene.partkey, [.transcriptPath(nil)])
        case "ファイルが無い":
            try FileManager.default.removeItem(at: url)
        default:
            try Data("{こわれた".utf8).write(to: url)
        }
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
        if fault == "列が NULL" {
            // 列の項だけを落とす
            #expect(DeletionPolicy.partTranscriptIsValid(c.part, ctx))
        } else {
            // partTranscriptIsValid だけを落とす
            #expect(DeletionPolicy.verifyRawNote(c.session, c.parts, ctx) == .passed)
        }
    }

    @Test("ND-36 [A] Vault の .obsidian が無ければ（空の Vault）消さない")
    func nd36EmptyVaultBlocks() async throws {
        let scene = try DeletionScene()
        try FileManager.default.removeItem(at: scene.vault.appendingPathComponent(".obsidian", isDirectory: true))
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
        #expect(DeletionPolicy.verifyRawNote(c.session, c.parts, ctx) == .vaultUnavailable)
    }

    @Test("ND-41 [A] reaper の署名が不正・版が違えば条件が偽（パラメータ化）", arguments: ["署名", "版"])
    func nd41InvalidReaperBlocks(_ fault: String) async throws {
        let scene: DeletionScene
        if fault == "署名" {
            scene = try DeletionScene()
            scene.verifier.setValid(false)
        } else {
            scene = try DeletionScene(reaperVersionOutput: "0.0.1\n")
        }
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(ctx.locks.readiness == .disabled("reaper_invalid"))
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
        if fault == "署名" {
            // 署名が不正なら --version も実行しない
            #expect(await scene.runner.recorded.isEmpty)
        }
    }

    @Test(
        "ND-45 [A] reaper.conf が無い・不正・symlink なら消さない（不明は安全側。パラメータ化）", arguments: ["無い", "不正", "symlink"])
    func nd45UnknownReaperConfBlocks(_ fault: String) async throws {
        let scene = try DeletionScene()
        switch fault {
        case "無い":
            try scene.removeReaperConf()
        case "不正":
            try scene.writeReaperConfRaw(Data("SCHEMA=1\nDELETE_SOURCE_AUDIO=maybe\n".utf8))
        default:
            let other = scene.tmp.url.appendingPathComponent("other.conf", isDirectory: false)
            try ReaperConf(deleteSourceAudio: true, volumesRoot: scene.volumesRoot.path(percentEncoded: false))
                .render().write(to: other)
            try scene.removeReaperConf()
            try FileManager.default.createSymbolicLink(
                atPath: scene.layout.reaperConf.path(percentEncoded: false),
                withDestinationPath: other.path(percentEncoded: false))
        }
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(ctx.locks.readiness == .disabled("lock_mismatch"))
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
    }
}
