// Part の工程: 文字起こしの呼び手の手順（PLAN §8.4「呼び手の手順」）と、16 kHz が無いときの戻し（ASR-04 / SM-17）。
import Foundation
import VDContract
import VDCore
import VDStore
import VDTranscribe

extension PartSteps {
    /// TRANSCRIBED 以降なら真。NORMALIZED / TRANSCRIBING から文字起こしする。
    func ensureTranscribed(_ row: RecordingRow) async -> Bool {
        if PartStates.transcribedOrBeyond.contains(row.status) { return true }
        guard PartStates.transcribable.contains(row.status), let normalizedPath = row.normalizedPath else {
            return false
        }
        return await guarded { try await transcribe(row, normalizedPath: normalizedPath) }
    }

    private func transcribe(_ row: RecordingRow, normalizedPath: String) async throws -> Bool {
        let pk = row.partkey
        let slug = KeySlug.of(pk)
        let deps = ctx.deps
        // 1. ガード（遷移しない）
        let transcriber = Transcriber(
            runner: deps.runner, paths: deps.paths, layout: layout, config: cfg.transcription, catalog: deps.catalog,
            clock: clock)
        let missing = transcriber.missingPrerequisites()
        if !missing.isEmpty {
            for m in missing {
                if let r = PauseReason(rawValue: m.rawValue) { ctx.pauses.trip(r) }
            }
            return false
        }
        // 2. 16 kHz が無ければ変換し直すか NORMALIZED_MISSING
        let input = layout.url(relative: normalizedPath)
        if !FileProbe.isNonEmptyRegularFile(input) {
            return try renormalizeOrFail(row)
        }
        // 3. NORMALIZED から来たときだけ記録する
        if row.status == .normalized {
            try store.recordPartTransition(partkey: pk, from: .normalized, to: .transcribing)
        }
        // 4〜5. 文字起こし（冪等とタイムアウトは Transcriber が行う）
        ctx.activity.set(.transcribing(partkey: pk, startedAt: row.startedAt))
        let outcome = await transcriber.transcribe(
            TranscribeRequest(
                partkey: pk, slug: slug, input: input, durationSeconds: row.durationSeconds, startedAt: row.startedAt))
        let transcriptRel = layout.relativePath(of: layout.transcript(slug: slug))
        // 6. 結果の写し方
        switch outcome {
        case .prerequisiteMissing(let m):
            if let r = PauseReason(rawValue: m.rawValue) { ctx.pauses.trip(r) }
            return false
        case .stopped:
            // アプリの終了で止めた・閉じた後で起動しなかった。失敗にせず行を動かさない（TRANSCRIBING のまま。
            // 次回起動時の復旧が TRANSCRIBING→NORMALIZED に戻す。PLAN §8.15。F-82）
            return false
        case .noSpeech(_, let message):
            try store.updateRecording(pk, [.transcriptPath(transcriptRel)])
            try skip(row, from: .transcribing, code: .noSpeechDetected, message: message)
            return false
        case .failure(let f):
            try fail(row, from: .transcribing, code: f.code, message: f.message, event: .transcriptionFailed)
            return false
        case .transcribed(_, let metrics):
            try store.updateRecording(pk, [.transcriptPath(transcriptRel), .errorCode(nil), .errorMessage(nil)])
            try store.recordPartTransition(partkey: pk, from: .transcribing, to: .transcribed)
            log.info(
                .transcriptionCompleted,
                [
                    (.recordingKey, .string(pk)),
                    (.elapsedS, .double(PyRound.round(metrics.elapsedSeconds, digits: 1))),
                    (.chars, .of(metrics.chars)), (.rtf, .of(metrics.rtf)), (.speechRatio, .of(metrics.speechRatio)),
                ])
            if cfg.cleanup.deleteNormalizedAfterTranscribe {
                do {
                    try SafeUnlink.remove(input, under: .staging, layout: layout)
                } catch {
                    log.warning(.diskSpaceLow, [(.recordingKey, .string(pk)), (.reason, "staging_unlink_failed")])
                }
            }
            return true
        }
    }

    /// 16 kHz が無いとき（voicedock pipeline.py:1623-1652）。inbox が在れば NORMALIZING に戻すだけ、無ければ NORMALIZED_MISSING。
    /// F-82: inbox を先に確かめ、無ければ**今の状態のまま** needs_recopy = 1 を書いてから →NORMALIZING に進む。
    /// 遷移を先に書くと、間で落ちたとき needs_recopy = 0 の NORMALIZING が残り、復旧（→DISCOVERED）の後に
    /// SOURCE_MISSING の SKIPPED（終端）になって再コピーされない。
    func renormalizeOrFail(_ row: RecordingRow) throws -> Bool {
        let pk = row.partkey
        let inboxPresent = row.inboxPath.map { FileProbe.isNonEmptyRegularFile(layout.url(relative: $0)) } ?? false
        if !inboxPresent {
            // 状態が変わっていれば（TransitionConflict と同じく）何も書かずに次へ
            guard try store.updateRecordingIfStatus(pk, status: row.status, [.needsRecopy(true)]) else { return false }
        }
        try store.recordPartTransition(partkey: pk, from: row.status, to: .normalizing)
        if inboxPresent { return false }
        try fail(
            row, from: .normalizing, code: .normalizedMissing,
            message: "16 kHz 音声も inbox の原本もありません（\(row.normalizedPath ?? "")）。デバイスから採り直す必要があります",
            event: .normalizeFailed, reason: "input")
        return false
    }
}
