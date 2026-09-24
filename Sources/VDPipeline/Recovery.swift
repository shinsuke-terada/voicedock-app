// 起動時の復旧（PLAN §5.3。voicedock pipeline.py:1669-1728 と同じ順）。進行中の状態を 1 つ手前に戻す。PT-21 の許可場所。
import Foundation
import VDContract
import VDCore
import VDStore

/// 起動時の復旧（PLAN §5.3）。
struct Recovery {
    let store: Store
    let layout: HomeLayout
    let log: AppLog
    let config: AppConfig
    let zone: ZonedTime

    /// 戻した行の数。DB の例外は投げる（TransitionConflict は数えずに次へ）。
    func run() throws -> Int {
        var moved = 0
        for edge in TransitionTable.partRecovery {
            for row in try store.recordings(status: edge.from) {
                discardPartial(part: row, state: edge.from)
                do {
                    try store.recordPartTransition(partkey: row.partkey, from: edge.from, to: edge.to, kind: .recovery)
                } catch is TransitionConflict {
                    continue
                }
                moved += 1
            }
        }
        for edge in TransitionTable.sessionRecovery {
            for row in try store.sessions(status: edge.from) {
                discardPartial(session: row, state: edge.from)
                do {
                    try store.recordSessionTransition(
                        sessionKey: row.sessionKey, from: edge.from, to: edge.to, kind: .recovery)
                } catch is TransitionConflict {
                    continue
                }
                moved += 1
            }
        }
        if moved > 0 {
            log.info(.recoveryCompleted, [(.rolledBack, .of(moved))])
        }
        return moved
    }

    /// 戻す前の Part の部分出力の削除。NORMALIZING は partkey から算出する（列は見ない）。
    /// SOURCE_DELETING は何もしない（delete_request_id を外さない。§8.9.6 が回収する）。
    func discardPartial(part row: RecordingRow, state: PartStatus) {
        let slug = KeySlug.of(row.partkey)
        switch state {
        case .normalizing:
            discard(layout.normalizedAudio(slug: slug), under: .staging)
            discard(layout.normalizedAudioTmp(slug: slug), under: .staging)
        case .transcribing:
            discard(layout.transcript(slug: slug), under: .transcripts)
            discard(layout.whisperJSON(slug: slug), under: .staging)
            // 話者分離の途中で落ちた RTTM（PLAN §8.4.1。F-90）
            discard(layout.diarizationRTTM(slug: slug), under: .staging)
        case .rawWriting:
            discardVaultTmp(part: row)
        default:
            break
        }
    }

    /// 戻す前の Session の部分出力の削除。WRITING だけ（Vault の一時ファイル。T-29）。
    func discardPartial(session row: SessionRow, state: SessionStatus) {
        if state == .writing {
            discardVaultTmp(session: row)
        }
    }

    /// 消せなくても続ける（config_warning rule=recovery）。
    private func discard(_ url: URL, under root: SafeUnlinkRoot) {
        do {
            try SafeUnlink.remove(url, under: root, layout: layout, missingOK: true)
        } catch {
            let shown = layout.relativePath(of: url) ?? url.path(percentEncoded: false)
            log.warning(
                .configWarning,
                [(.rule, "recovery"), (.message, .string("\(shown) を消せません: \(ErrorText.describe(error))"))])
        }
    }
}
