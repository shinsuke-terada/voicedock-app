// Daily ノート（PLAN §5.6 末尾・§8.6〜§8.8 の呼び手の手順。voicedock pipeline.py:1229-1400 ＋ v1.1）。
import Foundation
import VDContract
import VDCore
import VDLLM
import VDNotes
import VDStore

extension SessionSteps {
    /// ANALYZED / WRITING → SAVED。SAVED 以降なら真。遷移を記録してから解析 JSON を読む。
    func ensureDailyNote(_ key: String, _ t: SessionTranscript) async -> Bool {
        guarded { try writeDailyNote(key, t) }
    }

    /// Daily の入力（T-27 の DailyInput）。
    func dailyInput(
        row: SessionRow, analysis: AnalysisResult, parts: [RecordingRow], day: LocalDate, transcript: SessionTranscript
    ) -> DailyInput {
        let key = row.sessionKey
        // 1. どちらも started_at, partkey 順のまま
        let included = parts.filter { $0.status != .failed && $0.status != .skipped }
        let excluded = parts.filter { $0.status == .failed || $0.status == .skipped }
        // 2.
        let fp = TranscriptFingerprint.of(transcript, zone: zone)
        // 3. 保存済みの Map 結果を優先する。読めない・指紋が違う → 空 → 代替経路
        var blocks = Timeline.decode(
            (try? Data(contentsOf: layout.timelineJSON(sessionSlug: KeySlug.of(key)))) ?? Data(), fingerprint: fp,
            zone: zone)
        if blocks.isEmpty {
            blocks = Timeline.build(partials: [], chunks: [], transcript: transcript, summary: analysis.summary)
        }
        // 4. タグの候補は解析の tags そのもの。Raw のリンク先は DB の raw_output_path の basename（X-15）
        let w = cfg.obsidian
        let plan = LinkPlanner.plan(
            config: w, day: day, tags: analysis.tags ?? [], index: w.wiki.linkTags ? ctx.vaultIndex : nil,
            selfName: DailyNote.baseName(config: w, day: day),
            nameForDay: { DailyNote.baseName(config: w, day: $0) },
            rawNames: [DailyNote.rawLinkName(rawOutputPath: row.rawOutputPath, config: w, day: day)])
        // 5. recordedSeconds は Session の列（除外 Part も含む）。未知のコードは生の文字列を unknownCode に（M-1）
        return DailyInput(
            analysis: AnalysisView(analysis), day: day, sessionKey: key, recordingKeys: included.map(\.partkey),
            excluded: excluded.map {
                ExcludedPart(
                    partkey: $0.partkey, status: $0.status, errorCode: $0.errorCode,
                    unknownCode: $0.errorCode == nil ? $0.errorCodeRaw : nil,
                    rawNoteBlocked: PartSteps.isRawNoteBlocked($0))
            },
            recordedSeconds: row.recordedSeconds, blockCount: transcript.blocks.count, timeline: blocks, links: plan,
            zone: zone)
    }

    private func writeDailyNote(_ key: String, _ t: SessionTranscript) throws -> Bool {
        // 0.
        guard let row = try store.session(key) else { return false }
        if SessionStates.savedOrBeyond.contains(row.status) { return true }
        guard SessionStates.writable.contains(row.status), row.analysisPath != nil else { return false }
        guard let day = LocalDate(dashed: row.dayDate) else { return false }
        // 1. ガード（遷移しない）
        let status = VaultCheck.evaluate(path: cfg.vault.path, marker: cfg.vault.marker)
        if !status.isAvailable {
            ctx.pauses.trip(status == .notConfigured ? .vaultNotConfigured : .vaultUnavailable)
            return false
        }
        // 2.
        ctx.activity.set(.writingDailyNote(sessionKey: key, dayDate: row.dayDate))
        // 3. 遷移を記録してから解析 JSON を読む。WRITING から来たら記録しない
        if row.status == .analyzed {
            try store.recordSessionTransition(sessionKey: key, from: .analyzed, to: .writing)
        }
        // 4.
        guard let analysis = loadAnalysis(key) else {
            try failSession(
                key, from: .writing, code: .obsidianWriteFailed, message: "解析結果を読めません: \(row.analysisPath ?? "")",
                event: .obsidianFailed, reason: "write")
            return false
        }
        // 5. もう一度確かめる
        let status2 = VaultCheck.evaluate(path: cfg.vault.path, marker: cfg.vault.marker)
        guard status2.isAvailable, let path = cfg.vault.path else {
            try failSession(
                key, from: .writing, code: .obsidianNotFound,
                message: status2.message(path: cfg.vault.path ?? "", marker: cfg.vault.marker),
                event: .obsidianFailed, reason: "vault")
            return false
        }
        // 6.
        let parts = try store.recordings(inSession: key)
        let input = dailyInput(row: row, analysis: analysis, parts: parts, day: day, transcript: t)
        let content = DailyNote.render(input, config: cfg)
        // 7.
        let vault = VaultPaths.root(path)
        let folder: URL
        do {
            folder = try NoteFolder.ensure(relative: DailyNote.folder(config: cfg.obsidian, day: day), vault: vault)
        } catch {
            try failSession(
                key, from: .writing, code: .obsidianWriteFailed, message: NoteErrorText.describe(error),
                event: .obsidianFailed, reason: "write")
            return false
        }
        // 8.
        let target: URL
        switch OutputPathResolver.resolve(
            folder: folder, baseName: DailyNote.baseName(config: cfg.obsidian, day: day),
            existing: row.outputPath.map { VaultPaths.url($0, vault: vault) }, sessionKey: key,
            ownedPartkeys: Set(parts.map(\.partkey)), kind: .daily)
        {
        case .failure(let f):
            try failSession(
                key, from: .writing, code: f.code, message: f.message, event: .obsidianFailed, reason: "write")
            return false
        case .success(let url):
            target = url
        }
        // 9.
        let sha: String
        do {
            sha = try NoteWriter.write(content, to: target)
        } catch {
            try failSession(
                key, from: .writing, code: .obsidianWriteFailed, message: NoteErrorText.describe(error),
                event: .obsidianFailed, reason: "write")
            return false
        }
        // 10. DN-7 は included の鍵と完全一致
        let v = NoteVerifier.verify(
            url: target, kind: .daily, sessionKey: key, expectedSHA256: sha, expectedKeys: Set(input.recordingKeys),
            summaryHeading: DailyNote.summaryHeading(config: cfg))
        if !v.passed {
            try failSession(
                key, from: .writing, code: .obsidianVerifyFailed, message: v.failureMessage, event: .obsidianFailed,
                reason: "verify")
            return false
        }
        // 11.
        let rel = VaultPaths.relative(target, vault: vault)
        try store.updateSession(key, [.outputPath(rel), .outputSHA256(sha), .errorCode(nil), .errorMessage(nil)])
        try store.recordSessionTransition(sessionKey: key, from: .writing, to: .saved)
        // 12.
        log.info(
            .obsidianSaved, [(.sessionKey, .string(key)), (.path, .string(rel)), (.bytes, .of(content.utf8.count))])
        return true
    }
}
