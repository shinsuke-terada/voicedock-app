// Part の工程: 16 kHz 変換の呼び手の手順（PLAN §8.3「呼び手の手順」）。
import Foundation
import VDAudio
import VDContract
import VDCore
import VDStore

extension PartSteps {
    /// NORMALIZED 以降なら真。DISCOVERED / NORMALIZING から変換する。FAILED / SKIPPED は進めない。
    func ensureNormalized(_ row: RecordingRow) async -> Bool {
        if PartStates.normalizedOrBeyond.contains(row.status) { return true }
        if !PartStates.normalizable.contains(row.status) { return false }
        return await guarded { try await normalize(row) }
    }

    private func normalize(_ row: RecordingRow) async throws -> Bool {
        let pk = row.partkey
        let slug = KeySlug.of(pk)
        let cfg = self.cfg
        let layout = self.layout
        let clock = self.clock
        // 1. inbox の原本（needs_recopy なら再コピーを待つ）
        guard let inbox = row.inboxPath.map({ layout.url(relative: $0) }), FileProbe.isNonEmptyRegularFile(inbox)
        else {
            if row.needsRecopy { return false }
            try skip(
                row, from: row.status, code: .sourceMissing, message: "inbox に原本がありません: \(row.inboxPath ?? "")")
            return false
        }
        // 2. 空き容量のガード（遷移しない。SM-18）
        let space =
            (try? await BlockingIO.run {
                SpaceCheck(config: cfg.audio, layout: layout).check(durationSeconds: row.durationSeconds)
            }) ?? .insufficient("空き容量を確認できません")
        if case .insufficient(let msg) = space {
            ctx.pauses.trip(.diskSpaceLow, recordingKey: pk, detail: msg)
            return false
        }
        // 3. NORMALIZING から来たら記録しない（SM-08）
        if row.status == .discovered {
            try store.recordPartTransition(partkey: pk, from: .discovered, to: .normalizing)
        }
        // 4. 変換
        ctx.activity.set(.normalizing(partkey: pk, startedAt: row.startedAt))
        let outputRel = layout.relativePath(of: layout.normalizedAudio(slug: slug)) ?? ""
        let claimed = try store.recording(normalizedPath: outputRel)?.partkey
        let t0 = clock.uptime()
        let store = ctx.deps.store
        let outcome = await Normalizer(config: cfg.audio, layout: layout, clock: clock).normalize(
            NormalizeRequest(
                input: inbox, partkey: pk, durationSeconds: row.durationSeconds, sha256Helper: row.sha256Helper,
                claimedBy: claimed, duplicateOf: { sha in (try? store.recording(sha256: sha))??.partkey }))
        switch outcome {
        case .duplicate(let other, _):
            // 5. duplicate_of を先に書く。sha256 は書かない（部分 UNIQUE）
            try store.updateRecording(pk, [.duplicateOf(other)])
            try skip(
                row, from: .normalizing, code: .duplicateContent, message: "同じ内容の Part が既にあります: \(other)")
            return false
        case .failure(let f):
            // 6. 再コピーの要る失敗は列を遷移より先に書く（§11 の提案 5）。SOURCE_HASH_MISMATCH と、F-82 で
            //    入力のヘッダが実データより短い NORMALIZE_VERIFY_FAILED（機器がヘッダを直していれば取り直しで直る）
            if Self.needsRecopy(f) {
                _ = try store.updateRecordingIfStatus(pk, status: .normalizing, [.needsRecopy(true)])
            }
            try fail(row, from: .normalizing, code: f.code, message: f.message, event: .normalizeFailed)
            return false
        case .success(let sha, let output, let inBytes, let outBytes, _):
            // 7. DB を書いてから inbox を消す（CONC-08）。needs_recopy も下ろす（F-82。立ったままだと、後で FAILED に
            //    なったときに requeue（契機 1〜3）から外れ、済んだ Part を取り直す）
            try store.updateRecording(
                pk,
                [
                    .sha256(sha), .normalizedPath(layout.relativePath(of: output)),
                    .stagingDir(layout.relativePath(of: layout.stagingDirectory(slug: slug))), .errorCode(nil),
                    .errorMessage(nil), .needsRecopy(false),
                ])
            try store.recordPartTransition(partkey: pk, from: .normalizing, to: .normalized)
            log.info(
                .normalizeCompleted,
                [
                    (.recordingKey, .string(pk)), (.inBytes, .of(inBytes)), (.outBytes, .of(outBytes)),
                    (.elapsedS, .double(PyRound.round(DurationSeconds.of(clock.uptime() - t0), digits: 1))),
                ])
            if cfg.audio.retain == .normalized {
                try? SafeUnlink.remove(inbox, under: .inbox, layout: layout)
            }
            return true
        }
    }
}

extension PartSteps {
    /// F-77 の「入力のヘッダの長さと実データの量が合いません（…）」の先頭（VDAudio の `InputExtentCheck` の文言。
    /// 文言が変われば `PartStepsRecopyTests` の本物の変換のテストが落ちる）
    static let inputExtentMismatchPrefix = "入力のヘッダの長さと実データの量が合いません"

    /// 変換の失敗のうち、デバイスから取り直せば直りうるもの（needs_recopy を立てる。PLAN §8.3 手順 6）。
    /// F-82: 入力のヘッダが実データより短い NORMALIZE_VERIFY_FAILED も（利用者の決定 2026-09-23）。取り直しは変換し直すたびに
    /// 高々 1 回（requeueRecopied（契機 4）の対象にしないので、取り直した原本を変換し直すのは次の再評価の契機（接続・起動・
    /// 再試行）。接続している間 走査ごとに繰り返さない。直っていなければまた不合格になるだけで、inbox の原本も元の録音も消さない）
    static func needsRecopy(_ failure: StageFailure) -> Bool {
        switch failure.code {
        case .sourceHashMismatch: true
        case .normalizeVerifyFailed:
            failure.message.unicodeScalars.starts(with: inputExtentMismatchPrefix.unicodeScalars)
        default: false
        }
    }
}
