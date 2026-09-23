// 1 件の要求の検証と実行（PLAN §8.9.4 の表。RV-02〜RV-13）。
import Darwin
import Foundation
import VDContract

enum RequestOutcome: Equatable, Sendable {
    /// `rejected/` へ退避した（結果も processed.log も書かない）
    case rejectedFileName
    /// 拒否（processed.log → 結果 SOURCE_IDENTITY_MISMATCH → 要求を消す）
    case refused(String)
    /// 残す（何も書かない。アプリ側の期限切れが取り下げる）
    case left(String)
    case deleted(relpath: String)
    /// 列挙の後に要求が消えていた（取り下げと重なった）。何も書かない（ログも出さない）。数えない（F-73）
    case gone
    /// unlink の直前に読み直した reaper.conf でロック 1 が閉じていた（lock1 / conf_invalid）。
    /// 要求を残し（processed.log にも結果にも書かない）、呼び手は走査を終える（F-73）
    case stopped(String)
}

struct RequestProcessor {
    let layout: HomeLayout
    let conf: ReaperConf
    let queue: QueueFiles
    let log: ReaperLog
    let clock: ReaperClock
    var processed: ProcessedLog

    /// 1 件を処理して結果を返す（ログもここで書く）。PLAN §8.9.4 の表の順。1 つでも偽なら削除しない
    mutating func process(name: String) -> RequestOutcome {
        // RV-02a
        guard QueueFiles.isRequestFileName(name) else { return reject(name: name) }
        let stem = QueueFiles.stem(of: name)
        // 読み取り
        let data: Data
        switch queue.readRequest(named: name) {
        case .gone:
            // 取り下げと重なった。partkey の無い結果を書かない（アプリが片付けられない。F-73）
            return .gone
        case .unreadable:
            return refuse(name: name, stem: stem, deviceID: "", partkey: "", reason: IdentityReason.malformedRequest)
        case .read(let bytes):
            data = bytes
        }
        // RV-02b。request_id は結果ファイルの名前になる。信用できない値をファイル名にしない（d419397 / ND-38）
        guard let object = try? JSONSerialization.jsonObject(with: data), let dict = object as? [String: Any] else {
            return refuse(name: name, stem: stem, deviceID: "", partkey: "", reason: IdentityReason.malformedRequest)
        }
        guard let innerID = dict["request_id"] as? String, Self.scalarsEqual(innerID, stem) else {
            return reject(name: name)
        }
        // RV-03
        let r: DeleteRequest
        switch ContractJSON.decodeRequest(data) {
        case .failure:
            return refuse(name: name, stem: stem, deviceID: "", partkey: "", reason: IdentityReason.malformedRequest)
        case .success(let request):
            r = request
        }
        // RV-04。processed.log には再追記しない。結果が在れば書かない（DELETED を MISMATCH で上書きしない）
        if processed.contains(stem) {
            if !queue.resultExists(requestID: stem) {
                // 結果を書けなければ要求を残して次へ（拒否のログも出さない。refuse と同じ。F-73）
                guard
                    queue.writeResult(
                        result(
                            stem: stem, deviceID: r.deviceID, partkey: r.partkey, status: .sourceIdentityMismatch,
                            detail: IdentityReason.replayed))
                else { return .refused(IdentityReason.replayed) }
            }
            _ = Unlinker.removeRequest(named: name, inQueueDelete: queue.deleteFD)
            log.warn(
                ReaperLog.Event.sourceDeleteRejected,
                [(ReaperLog.Key.requestID, stem), (ReaperLog.Key.reason, IdentityReason.replayed)])
            return .refused(IdentityReason.replayed)
        }
        // RV-05。partkey の照合であって組み立てではない（PartKey.make を使うと ND-24 の理由語が変わる）
        guard Self.scalarsEqual(r.deviceID + "/" + r.target.relpath, r.partkey) else {
            return refuse(
                name: name, stem: stem, deviceID: r.deviceID, partkey: r.partkey,
                reason: IdentityReason.partkeyMismatch)
        }
        // RV-06
        let volume: VolumeHandle
        switch TargetIdentity.openVolume(volumesRoot: conf.volumesRoot, deviceID: r.deviceID) {
        case .absent:
            // 要求を残し processed にも書かない
            log.warn(
                ReaperLog.Event.deviceAbsent, [(ReaperLog.Key.requestID, stem), (ReaperLog.Key.device, r.deviceID)])
            return .left(IdentityReason.deviceAbsent)
        case .rejected(let mismatch):
            return refuse(name: name, stem: stem, deviceID: r.deviceID, partkey: r.partkey, reason: mismatch.reason)
        case .opened(let handle):
            volume = handle
        }
        // RV-07。要求を残す
        if volume.readOnly {
            log.warn(
                ReaperLog.Event.mountReadonly, [(ReaperLog.Key.requestID, stem), (ReaperLog.Key.device, r.deviceID)])
            return .left(IdentityReason.mountReadonly)
        }
        // RV-08〜RV-13。RV-13 は検証済みの親 fd の上で行う（開き直さない）。その直前に reaper.conf を読み直す（F-73）
        let confURL = layout.reaperConf
        let outcome = TargetIdentity.withVerifiedTarget(
            volume: volume, relpath: r.target.relpath,
            expectedSize: r.target.size, expectedMtime: r.target.mtime
        ) { target in
            Self.unlinkIfLock1Open(target, confURL: confURL)
        }
        switch outcome {
        case .failure(let mismatch):
            return refuse(name: name, stem: stem, deviceID: r.deviceID, partkey: r.partkey, reason: mismatch.reason)
        case .success(.lock1Closed(let reason)):
            // 走行中に無効化された。要求を残し、processed.log にも結果にも書かない
            log.info(ReaperLog.Event.disabled, [(ReaperLog.Key.reason, reason)])
            return .stopped(reason)
        case .success(.unlinked(.unlinkFailed)):
            return refuse(
                name: name, stem: stem, deviceID: r.deviceID, partkey: r.partkey, reason: IdentityReason.unlinkFailed)
        case .success(.unlinked(.stillPresent)):
            return refuse(
                name: name, stem: stem, deviceID: r.deviceID, partkey: r.partkey, reason: IdentityReason.stillPresent)
        case .success(.unlinked(.ok)):
            break
        }
        // 成功の書き込み順: processed.log → 結果 DELETED → 要求を消す → ログ
        processed.append(stem)
        let written = queue.writeResult(
            result(stem: stem, deviceID: r.deviceID, partkey: r.partkey, status: .deleted, detail: r.target.relpath))
        // 結果を書けなければ要求を残して次へ（source_deleted は出す）
        if written {
            _ = Unlinker.removeRequest(named: name, inQueueDelete: queue.deleteFD)
        }
        log.info(
            ReaperLog.Event.sourceDeleted, [(ReaperLog.Key.requestID, stem), (ReaperLog.Key.partkey, r.partkey)])
        return .deleted(relpath: r.target.relpath)
    }

    /// RV-02a / RV-02b。`rejected/` へ退避する（失敗は無視）。結果も processed.log も書かない
    private func reject(name: String) -> RequestOutcome {
        _ = queue.moveToRejected(named: name)
        log.warn(
            ReaperLog.Event.requestRejected,
            [(ReaperLog.Key.file, name), (ReaperLog.Key.reason, IdentityReason.malformedRequestID)])
        return .rejectedFileName
    }

    /// 拒否の書き込み（processed.log → 結果 → 要求を消す → ログ）
    private mutating func refuse(
        name: String, stem: String, deviceID: String, partkey: String, reason: String
    ) -> RequestOutcome {
        processed.append(stem)
        // 結果を書けていないのに「拒否した」と記録しない（要求を残す。アプリ側の期限切れが取り下げる）
        guard
            queue.writeResult(
                result(
                    stem: stem, deviceID: deviceID, partkey: partkey, status: .sourceIdentityMismatch, detail: reason))
        else { return .refused(reason) }
        _ = Unlinker.removeRequest(named: name, inQueueDelete: queue.deleteFD)
        log.warn(
            ReaperLog.Event.sourceDeleteRejected, [(ReaperLog.Key.requestID, stem), (ReaperLog.Key.reason, reason)])
        return .refused(reason)
    }

    /// detail は DELETED なら relpath、MISMATCH なら理由語のどちらか一方（連結しない。PLAN §4.4）
    private func result(
        stem: String, deviceID: String, partkey: String, status: DeleteResultStatus, detail: String
    ) -> DeleteResult {
        DeleteResult(
            schema: Contract.resultSchema, requestID: stem, completedAt: clock.nowISO(),
            reaperVersion: AppVersion.string, deviceID: deviceID, partkey: partkey, status: status, detail: detail)
    }

    /// 鍵の照合はスカラー列で（Swift の == は正準等価で比べるため。00-api-map §0）
    static func scalarsEqual(_ a: String, _ b: String) -> Bool {
        Array(a.unicodeScalars) == Array(b.unicodeScalars)
    }

    /// RV-13 の段（withVerifiedTarget の body。F-73）
    enum UnlinkStep: Equatable, Sendable {
        /// 読み直した reaper.conf でロック 1 が閉じていた（理由語は lock1 / conf_invalid）。unlink していない
        case lock1Closed(String)
        case unlinked(Unlinker.UnlinkOutcome)
    }

    /// 検証済みの親 fd の上で呼ばれる。unlink の直前に reaper.conf を読み直し（走行中の無効化を見る。F-73）、
    /// ロック 1 が開いているときだけ unlink する
    static func unlinkIfLock1Open(_ target: VerifiedTarget, confURL: URL) -> UnlinkStep {
        if let reason = lock1ClosedReason(ReaperConf.observe(at: confURL)) { return .lock1Closed(reason) }
        return .unlinked(Unlinker.unlinkTarget(target))
    }

    /// ロック 1（RV-01）の判定。開いていれば nil。閉じていれば理由語（false は lock1、無い・読めない・不正は conf_invalid）
    static func lock1ClosedReason(_ observation: ReaperConfObservation) -> String? {
        switch observation {
        case .valid(let conf): return conf.deleteSourceAudio ? nil : IdentityReason.lock1
        case .missing, .invalid: return IdentityReason.confInvalid
        }
    }
}
