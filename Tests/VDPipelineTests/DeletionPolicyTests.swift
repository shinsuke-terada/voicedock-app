// DeletionPolicy の項ごとの単体（T-36 §6.2）。項を 1 つずつ落とす（DEL-05: どの項を消しても落ちるテストが在ること）。
import Darwin
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDStore

@testable import VDPipeline

@Suite("DeletionPolicy")
struct DeletionPolicyTests {
    static let dupFileName = "TX00_MIC002_20260912_093000_orig.wav"
    static let dupStartedAt = "2026-09-12T09:30:00+09:00"
    static let dupKey = "DJIMIC3/TX_MIC001_20260912_090000/TX00_MIC002_20260912_093000_orig.wav"

    static func evaluate(
        _ scene: DeletionScene, snapshot: DeviceSnapshot? = nil, partkey: String = DeletionScene.partkey
    )
        async throws -> (DeletionCandidate, DeletionContext)
    {
        let ctx = await scene.context(snapshot: snapshot ?? scene.snapshot())
        return (try scene.candidate(partkey), ctx)
    }

    /// 重複（SKIPPED・DUPLICATE_CONTENT）の Part を既定の日に足す（transcript も Raw への掲載も無し）
    @discardableResult
    static func addDuplicate(_ scene: DeletionScene, duplicateOf: String?) throws -> String {
        try scene.addPart(
            fileName: dupFileName, startedAt: dupStartedAt, status: .skipped, errorCode: .duplicateContent,
            duplicateOf: duplicateOf, transcript: false, inRawNote: false)
    }

    static func row(_ scene: DeletionScene, _ partkey: String) throws -> RecordingRow {
        try #require(try scene.store.recording(partkey))
    }

    static func session(_ scene: DeletionScene, _ key: String = DeletionScene.sessionKey) throws -> SessionRow {
        try #require(try scene.store.session(key))
    }

    @Test("snapshot にファイルが無ければ事前確認が偽")
    func fileAbsentFromSnapshotBlocks() async throws {
        let scene = try DeletionScene()
        let (c, ctx) = try await Self.evaluate(scene, snapshot: scene.snapshot(relpaths: []))
        #expect(DeletionPolicy.preIdentityCheck(c.part, ctx) == false)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
        #expect(ctx.locks.allReleased(for: c.part.deviceID))
    }

    @Test("snapshot にデバイスが無ければ偽")
    func deviceAbsentFromSnapshotBlocks() async throws {
        let scene = try DeletionScene()
        let (c, ctx) = try await Self.evaluate(scene, snapshot: scene.snapshot(includeDevice: false))
        #expect(DeletionPolicy.preIdentityCheck(c.part, ctx) == false)
        #expect(ctx.locks.writability("DJIMIC3") == .absent)
    }

    @Test("snapshot が無ければ偽")
    func nilSnapshotBlocks() async throws {
        let scene = try DeletionScene()
        let ctx = await scene.context(snapshot: nil)
        #expect(DeletionPolicy.canDeleteSource(try scene.candidate(), ctx) == false)
    }

    @Test("鍵と source_path が食い違えば偽")
    func keyThatDisagreesWithPathBlocks() async throws {
        let scene = try DeletionScene()
        let other = "TX_MIC001_20260912_090000/TX00_MIC002_20260912_090000_orig.wav"
        try scene.addPart(
            fileName: "TX00_MIC002_20260912_090000_orig.wav", startedAt: "2026-09-12T09:00:00+09:00",
            status: .rawSaved, inRawNote: false)
        try StorePaths.setSourcePath(scene.store, partkey: DeletionScene.partkey, other)
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(ctx.snapshot?.devices["DJIMIC3"]?.relpaths.contains(other) == true)
        #expect(DeletionPolicy.preIdentityCheck(c.part, ctx) == false)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
    }

    @Test("不健全な relpath は偽")
    func unsafeRelpathBlocks() async throws {
        let scene = try DeletionScene()
        try StorePaths.setSourcePath(scene.store, partkey: DeletionScene.partkey, "../" + DeletionScene.relpath)
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
    }

    @Test("source_size / source_mtime が無ければ偽（パラメータ化）", arguments: ["source_size", "source_mtime"])
    func missingSizeOrMtimeBlocks(_ column: String) async throws {
        let scene = try DeletionScene()
        let field: RecordingField = column == "source_size" ? .sourceSize(nil) : .sourceMtime(nil)
        try scene.store.updateRecording(DeletionScene.partkey, [field])
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
    }

    @Test("事前確認でボリュームが開けなければ偽")
    func unopenableVolumeBlocks() async throws {
        let scene = try DeletionScene()
        let root = scene.tmp.url.appendingPathComponent("NoVolumes", isDirectory: false).path(percentEncoded: false)
        try scene.writeReaperConfRaw(ReaperConf(deleteSourceAudio: true, volumesRoot: root).render())
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(ctx.locks.volumesRoot == root)
        #expect(DeletionPolicy.preIdentityCheck(c.part, ctx) == false)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
    }

    @Test("デバイス上のファイルのサイズが DB と違えば偽（withVerifiedTarget）")
    func changedFileOnDeviceBlocks() async throws {
        let scene = try DeletionScene()
        let url = scene.deviceRoot.appendingPathComponent(DeletionScene.relpath, isDirectory: false)
        var data = try Data(contentsOf: url)
        data.append(0x78)
        try data.write(to: url)
        let seconds = Int(DeletionScene.sourceMtime)
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        #expect(utimes(url.path(percentEncoded: false), &times) == 0)
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(ctx.snapshot?.devices["DJIMIC3"]?.relpaths.contains(DeletionScene.relpath) == true)
        #expect(DeletionPolicy.preIdentityCheck(c.part, ctx) == false)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
    }

    @Test("DEL-12 inbox のコピーの時刻（4 時間 34 分後）では事前確認が偽")
    func copyTimestampIsRejected() async throws {
        let scene = try DeletionScene()
        try scene.store.updateRecording(DeletionScene.partkey, [.sourceMtime(DeletionScene.sourceMtime + 16_440)])
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.preIdentityCheck(c.part, ctx) == false)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
    }

    @Test("Raw ノートが一致すれば passed")
    func verifierPassesWhenNoteMatches() async throws {
        let scene = try DeletionScene()
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.verifyRawNote(c.session, c.parts, ctx) == .passed)
    }

    @Test("raw_output_sha256 が無ければ notRecorded")
    func verifierNeedsRecordedSHA() async throws {
        let scene = try DeletionScene()
        try scene.store.updateSession(DeletionScene.sessionKey, [.rawOutputSHA256(nil)])
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.verifyRawNote(c.session, c.parts, ctx) == .notRecorded)
    }

    @Test("vault.path が nil なら vaultUnavailable")
    func verifierNeedsConfiguredVault() async throws {
        let scene = try DeletionScene()
        scene.updateConfig { $0.vault.path = nil }
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.verifyRawNote(c.session, c.parts, ctx) == .vaultUnavailable)
    }

    @Test("期待する鍵は Raw に載る Part だけ（書き手と同じ関数。BI-1）")
    func expectedKeysFollowRawNoteMembership() async throws {
        let scene = try DeletionScene()
        try scene.addPart(
            fileName: "TX00_MIC001_20260912_100000_orig.wav", folder: "TX_MIC001_20260912_100000",
            startedAt: "2026-09-12T10:00:00+09:00", status: .failed, errorCode: .obsidianRawWriteFailed,
            inRawNote: false)
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.canDeleteSource(c, ctx))
    }

    @Test("兄弟の Part が未完でも消せる（Part ごとに評価。DEL-04）")
    func unfinishedSiblingDoesNotBlock() async throws {
        let scene = try DeletionScene()
        try scene.addPart(
            fileName: "TX00_MIC001_20260912_100000_orig.wav", folder: "TX_MIC001_20260912_100000",
            startedAt: "2026-09-12T10:00:00+09:00", status: .transcribing, transcript: false, inRawNote: false)
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.canDeleteSource(c, ctx))
    }

    @Test("TRANSCRIBED の兄弟が Raw に未掲載なら、書き直すまで偽（RN-6）")
    func siblingNotYetInRawNoteBlocksUntilRewritten() async throws {
        let scene = try DeletionScene()
        try scene.addPart(
            fileName: "TX00_MIC001_20260912_100000_orig.wav", folder: "TX_MIC001_20260912_100000",
            startedAt: "2026-09-12T10:00:00+09:00", status: .transcribed)
        let (before, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.verifyRawNote(before.session, before.parts, ctx) == .failed(["RN-6"]))
        #expect(DeletionPolicy.canDeleteSource(before, ctx) == false)
        try scene.writeRawNote()
        let (after, ctx2) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.canDeleteSource(after, ctx2))
    }

    @Test("Daily ノートと解析の有無は条件にしない（AY-1）")
    func dailyNoteIsNotACondition() async throws {
        let scene = try DeletionScene()
        try scene.store.updateSession(
            DeletionScene.sessionKey, [.outputPath(nil), .outputSHA256(nil), .analysisPath(nil)])
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.canDeleteSource(c, ctx))
    }

    @Test("読めないノートの鍵は空（パラメータ化）", arguments: ["非 UTF-8", "frontmatter 無し", "配列でない"])
    func frontmatterKeysOfUnreadableNote(_ kind: String) async throws {
        let scene = try DeletionScene()
        let data: Data
        switch kind {
        case "非 UTF-8":
            data = Data([0x2D, 0x2D, 0x2D, 0x0A, 0xFF, 0xFE, 0x80, 0x0A, 0x2D, 0x2D, 0x2D, 0x0A])
        case "frontmatter 無し":
            data = Data("# 本文だけ\n\nおはようございます。\n".utf8)
        default:
            data = Data("---\nvoicedock_recording_keys: x\n---\n本文\n".utf8)
        }
        try data.write(to: try scene.rawNoteURL())
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.frontmatterKeys(c.session.rawOutputPath, ctx) == [])
    }

    @Test("transcript の妥当性は実ファイルで決める", arguments: ["既定", "ファイルを消す"])
    func transcriptValidityReadsTheFile(_ kind: String) async throws {
        let scene = try DeletionScene()
        if kind == "ファイルを消す" {
            try FileManager.default.removeItem(at: scene.transcriptURL(DeletionScene.partkey))
        }
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(c.part.transcriptPath != nil)
        #expect(DeletionPolicy.partTranscriptIsValid(c.part, ctx) == (kind == "既定"))
    }

    @Test("鍵はスカラー列で比べる（正準等価で一致させない）")
    func keysCompareByScalars() {
        #expect(DeletionPolicy.sameKey("が", "か\u{3099}") == false)
        #expect(DeletionPolicy.sameKey("a", "a"))
        #expect(DeletionPolicy.sameKey(nil, "a") == false)
    }

    @Test("candidate は Session・全 Part・双子を引く")
    func candidateLoadsTheSessionAndTwin() throws {
        let scene = try DeletionScene()
        let dup = try Self.addDuplicate(scene, duplicateOf: DeletionScene.partkey)
        let c = try #require(try DeletionCandidate.load(partkey: dup, store: scene.store))
        #expect(c.twin?.part.partkey == DeletionScene.partkey)
        #expect(c.twin?.session.sessionKey == DeletionScene.sessionKey)
        #expect(c.parts.count == 2)
    }

    @Test("Part か Session が無ければ nil（パラメータ化）", arguments: ["無い partkey", "session_key が nil"])
    func candidateIsNilWithoutSession(_ kind: String) throws {
        let scene = try DeletionScene()
        let partkey: String
        if kind == "無い partkey" {
            partkey = "DJIMIC3/TX_MIC001_20260912_090000/TX00_MIC008_20260912_090000_orig.wav"
        } else {
            try scene.store.updateRecording(DeletionScene.partkey, [.sessionKey(nil)])
            partkey = DeletionScene.partkey
        }
        #expect(try DeletionCandidate.load(partkey: partkey, store: scene.store) == nil)
    }

    @Test("duplicate_of の指す Part が無ければ双子は nil")
    func twinIsNilWhenTheRecordedTwinIsMissing() async throws {
        let scene = try DeletionScene()
        let dup = try Self.addDuplicate(scene, duplicateOf: "DJIMIC3/none/none_orig.wav")
        scene.updateConfig { $0.cleanup.deleteSkippedSource = true }
        let (c, ctx) = try await Self.evaluate(scene, partkey: dup)
        #expect(c.twin == nil)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
    }

    @Test("duplicate_of が nil の重複は、双子を渡しても根拠が無い")
    func duplicateWithoutDuplicateOfIsNotBacked() async throws {
        let scene = try DeletionScene()
        let dup = try Self.addDuplicate(scene, duplicateOf: nil)
        scene.updateConfig { $0.cleanup.deleteSkippedSource = true }
        let ctx = await scene.context(snapshot: scene.snapshot())
        let session = try Self.session(scene)
        let parts = try scene.store.recordings(inSession: DeletionScene.sessionKey)
        let twin = TwinPart(part: try Self.row(scene, DeletionScene.partkey), session: session, parts: parts)
        let c = DeletionCandidate(part: try Self.row(scene, dup), session: session, parts: parts, twin: twin)
        #expect(DeletionPolicy.skipReasonIsBacked(c, ctx) == false)
        // 対照: 指名すると真
        try scene.store.updateRecording(dup, [.duplicateOf(DeletionScene.partkey)])
        let named = DeletionCandidate(part: try Self.row(scene, dup), session: session, parts: parts, twin: twin)
        #expect(DeletionPolicy.skipReasonIsBacked(named, ctx))
    }

    @Test("duplicate_of で指名された双子だけを認める")
    func onlyTheRecordedTwinIsAccepted() async throws {
        let scene = try DeletionScene()
        let dup = try Self.addDuplicate(
            scene, duplicateOf: "DJIMIC3/TX_MIC001_20260912_090000/TX00_MIC009_20260912_120000_orig.wav")
        scene.updateConfig { $0.cleanup.deleteSkippedSource = true }
        let ctx = await scene.context(snapshot: scene.snapshot())
        let session = try Self.session(scene)
        let parts = try scene.store.recordings(inSession: DeletionScene.sessionKey)
        let twin = TwinPart(part: try Self.row(scene, DeletionScene.partkey), session: session, parts: parts)
        let c = DeletionCandidate(part: try Self.row(scene, dup), session: session, parts: parts, twin: twin)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
        // 対照: 指名を既定の partkey に直すと真
        try scene.store.updateRecording(dup, [.duplicateOf(DeletionScene.partkey)])
        let named = DeletionCandidate(part: try Self.row(scene, dup), session: session, parts: parts, twin: twin)
        #expect(DeletionPolicy.canDeleteSource(named, ctx))
    }

    @Test("duplicate_of が在っても twin が nil なら偽")
    func missingTwinArgumentIsNotBacked() async throws {
        let scene = try DeletionScene()
        let dup = try Self.addDuplicate(scene, duplicateOf: DeletionScene.partkey)
        scene.updateConfig { $0.cleanup.deleteSkippedSource = true }
        let ctx = await scene.context(snapshot: scene.snapshot())
        let parts = try scene.store.recordings(inSession: DeletionScene.sessionKey)
        let c = DeletionCandidate(
            part: try Self.row(scene, dup), session: try Self.session(scene), parts: parts, twin: nil)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
    }

    @Test("双子が別の日でも双子の Session で根拠 A を見る")
    func twinOnAnotherDayIsEvaluatedOnItsOwnSession() async throws {
        let scene = try DeletionScene()
        let otherDay = "DJIMIC3:20260911"
        try scene.addSession(key: otherDay, dayDate: "2026-09-11")
        let twin = try scene.addPart(
            fileName: "TX00_MIC001_20260911_090000_orig.wav", folder: "TX_MIC001_20260911_090000",
            startedAt: "2026-09-11T09:00:00+09:00", status: .rawSaved, sessionKey: otherDay, onDevice: false)
        try scene.writeRawNote(sessionKey: otherDay)
        let dup = try Self.addDuplicate(scene, duplicateOf: twin)
        scene.updateConfig { $0.cleanup.deleteSkippedSource = true }
        let (c, ctx) = try await Self.evaluate(scene, partkey: dup)
        #expect(c.twin?.session.sessionKey == otherDay)
        #expect(DeletionPolicy.canDeleteSource(c, ctx))
    }

    @Test("SKIPPED でなければ理由が揃っても根拠 B ではない")
    func nonSkippedPartIsNotGroundB() async throws {
        let scene = try DeletionScene(status: .failed, errorCode: .noSpeechDetected)
        scene.updateConfig { $0.cleanup.deleteSkippedSource = true }
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.nothingToPreserve(c, ctx) == false)
        #expect(DeletionPolicy.skipReasonIsBacked(c, ctx))
    }

    @Test("SOURCE_MISSING は許可リストに無く根拠も無い")
    func sourceMissingHasNoBasis() async throws {
        let scene = try DeletionScene(status: .skipped, errorCode: .sourceMissing)
        scene.updateConfig { $0.cleanup.deleteSkippedSource = true }
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.nothingToPreserve(c, ctx) == false)
        #expect(DeletionPolicy.skipReasonIsBacked(c, ctx) == false)
    }

    @Test("ロック 1 は根拠 B にも掛かる")
    func lockOneAlsoStopsGroundB() async throws {
        let scene = try DeletionScene(status: .skipped, errorCode: .noSpeechDetected)
        scene.updateConfig {
            $0.cleanup.deleteSkippedSource = true
            $0.cleanup.deleteSourceAudio = false
        }
        let (c, ctx) = try await Self.evaluate(scene)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
    }

    @Test("ロック 2-B も根拠 B に掛かる")
    func readOnlyAlsoStopsGroundB() async throws {
        let scene = try DeletionScene(status: .skipped, errorCode: .noSpeechDetected)
        scene.updateConfig { $0.cleanup.deleteSkippedSource = true }
        let (c, ctx) = try await Self.evaluate(scene, snapshot: scene.snapshot(readOnly: true))
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
    }

    @Test("許可リストの全理由に根拠の分岐がある（TEST-08）")
    func everyDeletableSkipReasonHasABasis() async throws {
        for code in SkipReasons.deletable {
            let scene: DeletionScene
            let partkey: String
            switch code {
            case .noSpeechDetected:
                scene = try DeletionScene(status: .skipped, errorCode: .noSpeechDetected)
                partkey = DeletionScene.partkey
            case .duplicateContent:
                scene = try DeletionScene()
                partkey = try Self.addDuplicate(scene, duplicateOf: DeletionScene.partkey)
            default:
                Issue.record("\(code) の舞台が無い")
                continue
            }
            scene.updateConfig { $0.cleanup.deleteSkippedSource = true }
            let (c, ctx) = try await Self.evaluate(scene, partkey: partkey)
            #expect(DeletionPolicy.skipReasonIsBacked(c, ctx), "\(code)")
        }
    }

    @Test("Raw ノートに当該の鍵が無ければ、RN-6 が空集合で通っても偽")
    func frontmatterKeysAloneBlocksWhenExpectedIsEmpty() async throws {
        let scene = try DeletionScene()
        let dup = try Self.addDuplicate(scene, duplicateOf: scene.partkey)
        scene.updateConfig { $0.cleanup.deleteSkippedSource = true }
        try scene.replaceInRawNote(scene.partkey, with: scene.deviceID + "/other/other.wav", updateSHA: true)
        let ctx = await scene.context(snapshot: scene.snapshot())
        let session = try Self.session(scene)
        let parts = try scene.store.recordings(inSession: scene.sessionKey)
        let twin = TwinPart(part: try Self.row(scene, scene.partkey), session: session, parts: [])
        let c = DeletionCandidate(part: try Self.row(scene, dup), session: session, parts: parts, twin: twin)
        // 期待する鍵が空集合なので RN-6 は通る。鍵の包含の項だけが落とす
        #expect(DeletionPolicy.verifyRawNote(session, [], ctx) == .passed)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
        // 対照: ノートを書き直して鍵を戻すと真
        try scene.writeRawNote()
        let restored = await scene.context(snapshot: scene.snapshot())
        let freshSession = try Self.session(scene)
        let freshTwin = TwinPart(part: try Self.row(scene, scene.partkey), session: freshSession, parts: [])
        let again = DeletionCandidate(
            part: try Self.row(scene, dup), session: freshSession, parts: parts, twin: freshTwin)
        #expect(DeletionPolicy.canDeleteSource(again, restored))
    }

    @Test("Part の session_key と渡された Session が食い違えば同定しない")
    func partFromAnotherSessionIsNotIdentified() async throws {
        let scene = try DeletionScene()
        let otherDay = "DJIMIC3:20260911"
        try scene.addSession(key: otherDay, dayDate: "2026-09-11")
        let pk = try scene.addPart(
            fileName: "TX00_MIC001_20260911_090000_orig.wav", folder: "TX_MIC001_20260911_090000",
            startedAt: "2026-09-11T09:00:00+09:00", status: .rawSaved, sessionKey: otherDay)
        try scene.writeRawNote(sessionKey: otherDay)
        // DB の session_key だけを既定の Session に変える（Raw ノートは 20260911 のまま）
        try scene.store.updateRecording(pk, [.sessionKey(scene.sessionKey)])
        let ctx = await scene.context(snapshot: scene.snapshot())
        let part = try Self.row(scene, pk)
        let other = try Self.session(scene, otherDay)
        let c = DeletionCandidate(part: part, session: other, parts: [part], twin: nil)
        #expect(DeletionPolicy.textIsPreserved(part, other, [part], ctx))
        #expect(DeletionPolicy.deletionIsIdentified(c, ctx) == false)
        #expect(DeletionPolicy.canDeleteSource(c, ctx) == false)
    }

    @Test("双子の session_key と双子の Session が食い違えば根拠が無い")
    func twinSessionMismatchIsNotBacked() async throws {
        let scene = try DeletionScene()
        let otherDay = "DJIMIC3:20260911"
        try scene.addSession(key: otherDay, dayDate: "2026-09-11")
        let twinKey = try scene.addPart(
            fileName: "TX00_MIC001_20260911_090000_orig.wav", folder: "TX_MIC001_20260911_090000",
            startedAt: "2026-09-11T09:00:00+09:00", status: .rawSaved, sessionKey: otherDay, onDevice: false)
        try scene.writeRawNote(sessionKey: otherDay)
        let dup = try Self.addDuplicate(scene, duplicateOf: twinKey)
        scene.updateConfig { $0.cleanup.deleteSkippedSource = true }
        let ctx = await scene.context(snapshot: scene.snapshot())
        let other = try Self.session(scene, otherDay)
        let original = try Self.row(scene, twinKey)
        // 双子の行の session_key だけを既定の Session に変える
        try scene.store.updateRecording(twinKey, [.sessionKey(scene.sessionKey)])
        let moved = try Self.row(scene, twinKey)
        let dupRow = try Self.row(scene, dup)
        let session = try Self.session(scene)
        let parts = try scene.store.recordings(inSession: scene.sessionKey)
        let c = DeletionCandidate(
            part: dupRow, session: session, parts: parts, twin: TwinPart(part: moved, session: other, parts: [moved]))
        #expect(DeletionPolicy.textIsPreserved(moved, other, [moved], ctx))
        #expect(DeletionPolicy.skipReasonIsBacked(c, ctx) == false)
        // 対照: 双子の行が双子の Session を指していれば真
        let backed = DeletionCandidate(
            part: dupRow, session: session, parts: parts,
            twin: TwinPart(part: original, session: other, parts: [original]))
        #expect(DeletionPolicy.skipReasonIsBacked(backed, ctx))
    }
}
