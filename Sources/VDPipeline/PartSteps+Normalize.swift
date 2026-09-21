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
            // 6. SOURCE_HASH_MISMATCH は列を遷移より先に書く（§11 の提案 5）
            if f.code == .sourceHashMismatch {
                _ = try store.updateRecordingIfStatus(pk, status: .normalizing, [.needsRecopy(true)])
            }
            try fail(row, from: .normalizing, code: f.code, message: f.message, event: .normalizeFailed)
            return false
        case .success(let sha, let output, let inBytes, let outBytes, _):
            // 7. DB を書いてから inbox を消す（CONC-08）
            try store.updateRecording(
                pk,
                [
                    .sha256(sha), .normalizedPath(layout.relativePath(of: output)),
                    .stagingDir(layout.relativePath(of: layout.stagingDirectory(slug: slug))), .errorCode(nil),
                    .errorMessage(nil),
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
