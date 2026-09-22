// Session の統合（PLAN §5.6「Block・統合」。voicedock session.py:329-423 / pipeline.py:1103-1138）。
import Foundation
import VDContract
import VDCore
import VDStore

extension SessionSteps {
    /// 有効な segment が 0 件なら nil（session_empty）。
    func buildSessionTranscript(_ key: String) throws -> SessionTranscript? {
        // 1.
        guard let row = try store.session(key), let day = LocalDate(dashed: row.dayDate) else { return nil }
        // 2. started_at, partkey 順
        let parts = try store.recordings(inSession: key)
        let valid = parts.filter { !Self.excludedStatuses.contains($0.status) }
        let excluded = parts.filter { Self.excludedStatuses.contains($0.status) }
        // 3. 絶対時刻（相対オフセットを足し込まない。TIME-01）。読めない Part は飛ばす
        var segments: [AbsoluteSegment] = []
        for p in valid {
            guard let started = zone.parseISO(p.startedAt), let t = readTranscript(p.partkey) else { continue }
            for seg in t.segments {
                let text = PyText.strip(seg.text)
                if text.isEmpty { continue }
                segments.append(
                    AbsoluteSegment(
                        at: started.adding(milliseconds: SecondsToMillis.fromWhisperSeconds(seg.start)),
                        endAt: started.adding(milliseconds: SecondsToMillis.fromWhisperSeconds(seg.end)),
                        text: text))
            }
        }
        // 4.
        if segments.isEmpty { return nil }
        // 5. (at, endAt) の epochMillis の組で安定ソート
        segments.sort { ($0.at.epochMillis, $0.endAt.epochMillis) < ($1.at.epochMillis, $1.endAt.epochMillis) }
        // 6. transcript が読めない Part も含む
        let blocks = BlockComputer.blocks(
            valid.compactMap { p in
                zone.parseISO(p.startedAt).map { (startedAt: $0, endedAt: p.endedAt.flatMap(zone.parseISO)) }
            },
            gapSeconds: cfg.session.blockGapSeconds)
        // 7.
        return SessionTranscript(
            dayDate: day, segments: segments, blocks: blocks, excludedPartkeys: excluded.map(\.partkey))
    }

    /// READY / MERGING → MERGED（有効な segment が無ければ COMPLETED）。
    func ensureMerged(_ row: SessionRow, _ t: SessionTranscript?) -> Bool {
        // 1.
        if SessionStates.mergedOrBeyond.contains(row.status) { return true }
        if !SessionStates.mergeable.contains(row.status) { return false }
        let key = row.sessionKey
        return guarded {
            // 2.
            let parts = try store.recordings(inSession: key)
            let excluded = parts.filter { Self.excludedStatuses.contains($0.status) }.count
            // 3. MERGING から来たら記録しない（再オープンの行もここから進む）
            if row.status == .ready {
                try store.recordSessionTransition(sessionKey: key, from: .ready, to: .merging)
            }
            // 4. ノートを作らない。FAILED にしない
            guard let t else {
                try store.recordSessionTransition(sessionKey: key, from: .merging, to: .completed)
                log.info(.sessionEmpty, [(.sessionKey, .string(key)), (.parts, .of(parts.count))])
                return false
            }
            // 5.
            try store.updateSession(key, [.failedPartCount(excluded)])
            try store.recordSessionTransition(sessionKey: key, from: .merging, to: .merged)
            log.info(
                .sessionMerged,
                [
                    (.sessionKey, .string(key)), (.parts, .of(parts.count - excluded)), (.excluded, .of(excluded)),
                    (.chars, .of(t.segments.reduce(0) { $0 + TextLimit.scalarCount($1.text) })),
                ])
            return true
        }
    }

    /// transcripts/parts/<slug>.json を読み PartTranscriptCodec.decode。読めなければ nil（列は見ない）。
    func readTranscript(_ partkey: String) -> PartTranscript? {
        guard let data = try? Data(contentsOf: layout.transcript(slug: KeySlug.of(partkey))) else { return nil }
        return PartTranscriptCodec.decode(data)
    }

    /// 統合から除く Part の状態（FAILED / SKIPPED）。
    static let excludedStatuses: Set<PartStatus> = [.failed, .skipped]
}
