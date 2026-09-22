// 削除要求の ①ID → ②要求ファイル（PLAN §4.4 の書く順）。③の遷移は呼び手（根拠 A と後追いは SOURCE_DELETING へ、根拠 B は遷移しない）。
import VDContract
import VDCore
import VDStore

/// 削除要求を書く唯一の場所（PR-09）。
struct RequestWriter {
    let deps: DeletionDependencies

    /// 書けたら request_id。書けなければ nil（理由はログに出してある）。Store の予期しない例外は投げる
    func write(part: RecordingRow, sessionKey: String) throws -> String? {
        // 1. 削除条件が真なら揃っている。防御
        guard let relpath = part.sourcePath, let size = part.sourceSize, let mtime = part.sourceMtime else {
            return nil
        }
        // 2.
        let now = deps.clock.now()
        let seconds = now.epochMillis >= 0 ? now.epochMillis / 1000 : -((-now.epochMillis + 999) / 1000)
        let id = RequestID.make(partkey: part.partkey, utcEpochSeconds: seconds, randomHex6: RequestID.randomHex6())
        // 3. ① ID を先に
        guard try deps.store.updateRecordingIfStatus(part.partkey, status: part.status, [.deleteRequestID(id)]) else {
            deps.logStatusChanged(recordingKey: part.partkey)
            return nil
        }
        // 4. DEL-12: size / mtime は DB の値 = デバイス上の原本。PR-17: 絶対パスを持たない
        let request = DeleteRequest(
            requestID: id, createdAt: deps.zone.iso(now), deviceID: part.deviceID, partkey: part.partkey,
            sessionKey: sessionKey, target: DeleteTarget(relpath: relpath, size: size, mtime: mtime))
        // 5. ② 要求ファイル
        do {
            try DeleteQueue.write(request, layout: deps.layout)
        } catch {
            try deps.store.updateRecording(part.partkey, [.deleteRequestID(nil)])
            deps.log.warning(
                .sourceDeletePending,
                [
                    (.recordingKey, .string(part.partkey)), (.reason, .string(DeletionReason.queueWriteFailed)),
                    (.errorCode, .string(ErrorCode.deleteQueueFailed.rawValue)),
                ])
            return nil
        }
        // 6.
        return id
    }
}
