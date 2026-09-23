// Part の工程: Raw ノートの書き込み（PLAN §8.6〜§8.8。voicedock pipeline.py:467-547, 592-623 ＋ v1.1 のガード）。
import Foundation
import VDContract
import VDCore
import VDNotes
import VDStore

extension PartSteps {
    /// TRANSCRIBED / RAW_WRITING → RAW_SAVED。RAW_SAVED 以降なら真。
    /// FAILED にするのはトリガの Part 1 件だけ（SM-15）。DB 更新が成功するまで保存済みとみなさない。
    /// F-75: トリガが Raw に載らないとき・書き直しで RAW_SAVED 以降の Part の本文が消えるときは書かずに FAILED。
    func ensureRawNote(_ row: RecordingRow) async -> Bool {
        if PartStates.rawSavedOrBeyond.contains(row.status) { return true }
        guard PartStates.rawWritable.contains(row.status), let key = row.sessionKey else { return false }
        return await guarded { try writeRawNote(row, sessionKey: key) }
    }

    /// Raw に載せる Part（RawNoteMembership で絞る。検証側（§8.9.1）と同じ関数）。started_at, partkey 順。
    func rawParts(sessionKey: String) throws -> [RawPart] {
        let zone = ctx.zone
        var parts: [RawPart] = []
        for p in try store.recordings(inSession: sessionKey) {
            let t = sessions.readTranscript(p.partkey)
            guard RawNoteMembership.isMember(status: p.status, transcriptReadable: t != nil) else { continue }
            guard let started = zone.parseISO(p.startedAt), let t else { continue }
            // text は strip しない（RawNote.render が strip する）
            parts.append(
                RawPart(
                    partkey: p.partkey, startedAt: p.startedAt, endedAt: p.endedAt,
                    segments: t.segments.map {
                        AbsoluteSegment(
                            at: started.adding(milliseconds: SecondsToMillis.fromWhisperSeconds($0.start)),
                            endAt: started.adding(milliseconds: SecondsToMillis.fromWhisperSeconds($0.end)),
                            text: $0.text)
                    }, zone: zone))
        }
        return parts
    }

    private func writeRawNote(_ row: RecordingRow, sessionKey key: String) throws -> Bool {
        // 1.
        guard let session = try store.session(key), let day = LocalDate(dashed: session.dayDate) else { return false }
        // 2. 載せる Part（空でも止まらない。トリガが載らなければ手順 6a で FAILED。F-75・X-38）
        let parts = try rawParts(sessionKey: key)
        // 3. ガード（遷移しない）
        let status = VaultCheck.evaluate(path: cfg.vault.path, marker: cfg.vault.marker)
        if !status.isAvailable {
            ctx.pauses.trip(status == .notConfigured ? .vaultNotConfigured : .vaultUnavailable)
            return false
        }
        // 4.
        ctx.activity.set(.writingRawNote(sessionKey: key))
        // 5. RAW_WRITING から来たら記録しない
        if row.status == .transcribed {
            try store.recordPartTransition(partkey: row.partkey, from: .transcribed, to: .rawWriting)
        }
        // 6. もう一度確かめる
        let status2 = VaultCheck.evaluate(path: cfg.vault.path, marker: cfg.vault.marker)
        guard status2.isAvailable, let path = cfg.vault.path else {
            try fail(
                row, from: .rawWriting, code: .obsidianNotFound,
                message: status2.message(path: cfg.vault.path ?? "", marker: cfg.vault.marker), event: .rawNoteFailed,
                reason: "vault")
            return false
        }
        // 6a. F-75: トリガが載らない（transcript が読めない）なら書かない。黙って止まらず、トリガ抜きで RAW_SAVED にもしない
        if !parts.contains(where: { PyText.scalarsEqual($0.partkey, row.partkey) }) {
            try fail(
                row, from: .rawWriting, code: .obsidianRawWriteFailed, message: unlistedReason(row),
                event: .rawNoteFailed, reason: "write")
            return false
        }
        // 7.
        let vault = VaultPaths.root(path)
        let content = RawNote.render(parts: parts, day: day, sessionKey: key, config: cfg.obsidian)
        // 8.
        let folder: URL
        do {
            folder = try NoteFolder.ensure(relative: RawNote.folder(config: cfg.obsidian, day: day), vault: vault)
        } catch {
            try fail(
                row, from: .rawWriting, code: .obsidianRawWriteFailed, message: NoteErrorText.describe(error),
                event: .rawNoteFailed, reason: "write")
            return false
        }
        // 9. 状態を問わず、この Session に属する全 Part
        let members = try store.recordings(inSession: key)
        let owned = Set(members.map(\.partkey))
        let existing = session.rawOutputPath.map { VaultPaths.url($0, vault: vault) }
        let target: URL
        switch OutputPathResolver.resolve(
            folder: folder, baseName: RawNote.baseName(config: cfg.obsidian, day: day), existing: existing,
            sessionKey: key, ownedPartkeys: owned, kind: .raw)
        {
        case .failure(let f):
            try fail(row, from: .rawWriting, code: f.code, message: f.message, event: .rawNoteFailed, reason: "write")
            return false
        case .success(let url):
            target = url
        }
        // 9a. F-75: 書き直すと RAW_SAVED 以降の Part（原本を消したかもしれない）の本文が消えるなら書かない
        let protectedKeys = Set(members.filter { PartStates.rawSavedOrBeyond.contains($0.status) }.map(\.partkey))
        guard
            let lost = OutputPathResolver.keysLostByOverwrite(
                target, protectedKeys: protectedKeys, newKeys: Set(parts.map(\.partkey)))
        else {
            try fail(
                row, from: .rawWriting, code: .obsidianRawWriteFailed,
                message: Self.unreadableNoteMessage + VaultPaths.relative(target, vault: vault), event: .rawNoteFailed,
                reason: "write")
            return false
        }
        if let first = lost.first {
            let why = members.first { PyText.scalarsEqual($0.partkey, first) }.map(unlistedReason) ?? ""
            try fail(
                row, from: .rawWriting, code: .obsidianRawWriteFailed,
                message: Self.lostTextMessage + "（" + String(lost.count) + " 本）: " + first + "。" + why,
                event: .rawNoteFailed, reason: "write")
            return false
        }
        // 10.
        let sha: String
        do {
            sha = try NoteWriter.write(content, to: target)
        } catch {
            try fail(
                row, from: .rawWriting, code: .obsidianRawWriteFailed, message: NoteErrorText.describe(error),
                event: .rawNoteFailed, reason: "write")
            return false
        }
        // 11.
        let v = NoteVerifier.verify(
            url: target, kind: .raw, sessionKey: key, expectedSHA256: sha, expectedKeys: Set(parts.map(\.partkey)),
            summaryHeading: DailyNote.summaryHeading(config: cfg))
        if !v.passed {
            try fail(
                row, from: .rawWriting, code: .obsidianRawVerifyFailed, message: v.failureMessage,
                event: .rawNoteFailed, reason: "verify")
            return false
        }
        // 12. 全部合格してから DB
        try store.updateSession(
            key, [.rawOutputPath(VaultPaths.relative(target, vault: vault)), .rawOutputSHA256(sha)])
        try store.recordPartTransition(partkey: row.partkey, from: .rawWriting, to: .rawSaved)
        // 13.
        log.info(
            .rawNoteSaved, [(.sessionKey, .string(key)), (.parts, .of(parts.count)), (.bytes, .of(content.utf8.count))])
        // 14. §8.3 手順 7 の同じ規則: DB 更新の後・失敗は無視。このトリガ Part の原本だけ
        if cfg.audio.retain == .rawSaved, let inboxPath = row.inboxPath {
            try? SafeUnlink.remove(layout.url(relative: inboxPath), under: .inbox, layout: layout)
        }
        // 15.
        _ = sessions.reopenSession(key)
        return true
    }

    /// F-75: 書き直すと本文が消える Part があるときの error_message の頭
    static let lostTextMessage = "書き直すと Raw ノートから本文が消える Part があります"
    /// F-75: 書き込み先の既存の Raw ノートが読めなくなったときの error_message の頭
    static let unreadableNoteMessage = "既存の Raw ノートを読めないので書き直しません: "

    /// F-75: Part が Raw に載らない理由（error_message）。transcript が読めないか、started_at が読めないか（rawParts の 2 つの条件）
    func unlistedReason(_ row: RecordingRow) -> String {
        if sessions.readTranscript(row.partkey) == nil {
            let url = layout.transcript(slug: KeySlug.of(row.partkey))
            return "文字起こしを読めません: " + (layout.relativePath(of: url) ?? url.path(percentEncoded: false))
        }
        return "開始時刻を読めません: " + row.startedAt
    }
}
