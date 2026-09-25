// 元音声の削除の必要十分条件（PLAN §8.9.1。式の形を変えない）とアプリ側の事前確認（§8.9.5）。
// 式の 5 つの関数の本体は DeletionFormulaTests（PolicyTests）がトークン単位で固定している。変えるなら PLAN を先に直す（TEST-30）。
import Foundation
import VDContract
import VDCore
import VDDevice
import VDNotes
import VDStore

/// 評価する 1 件。parts は Session の全 Part（Store.recordings(inSession:) の順）。
public struct DeletionCandidate: Sendable {
    public let part: RecordingRow
    public let session: SessionRow
    public let parts: [RecordingRow]
    /// 重複（DUPLICATE_CONTENT）の双子。根拠 B の重複だけが使う
    public let twin: TwinPart?

    public init(part: RecordingRow, session: SessionRow, parts: [RecordingRow], twin: TwinPart?) {
        self.part = part
        self.session = session
        self.parts = parts
        self.twin = twin
    }

    /// DB から組み立てる。Part が無い・session_key が nil・Session が無い → nil。twin は TwinPart.load
    public static func load(partkey: String, store: Store) throws -> DeletionCandidate? {
        guard let part = try store.recording(partkey), let key = part.sessionKey, let session = try store.session(key)
        else { return nil }
        let parts = try store.recordings(inSession: key)
        let twin = try TwinPart.load(for: part, store: store)
        return DeletionCandidate(part: part, session: session, parts: parts, twin: twin)
    }
}

/// 双子（先に正規化された同じ内容の Part）。session と parts は**双子の側**のもの（重複と双子は別の日でありうる）。
public struct TwinPart: Sendable {
    public let part: RecordingRow
    public let session: SessionRow
    public let parts: [RecordingRow]

    public init(part: RecordingRow, session: SessionRow, parts: [RecordingRow]) {
        self.part = part
        self.session = session
        self.parts = parts
    }

    /// 双子の引き方（voicedock pipeline.py:885-919 の _twin_of）: duplicate_of → その Part → その session_key → その Session → その Session の全 Part。どれかが欠ければ nil
    /// duplicate_of が指す Part が自分自身でも引く（弾くのは skipReasonIsBacked の番犬）。
    public static func load(for part: RecordingRow, store: Store) throws -> TwinPart? {
        guard let twinKey = part.duplicateOf, let twinRow = try store.recording(twinKey), let key = twinRow.sessionKey,
            let session = try store.session(key)
        else { return nil }
        return TwinPart(part: twinRow, session: session, parts: try store.recordings(inSession: key))
    }
}

public struct DeletionContext: Sendable {
    public let config: AppConfig
    public let locks: LockObservation
    public let layout: HomeLayout
    /// 事前確認のボリュームを開く（本番 SystemVolumeOpener。テスト FakeVolumeOpener。PLAN §4.6）
    public let volumeOpener: any VolumeOpener

    public init(config: AppConfig, locks: LockObservation, layout: HomeLayout, volumeOpener: any VolumeOpener) {
        self.config = config
        self.locks = locks
        self.layout = layout
        self.volumeOpener = volumeOpener
    }

    public var snapshot: DeviceSnapshot? { locks.snapshot }
    /// config.vault.path の URL（未設定なら nil）
    public var vaultRoot: URL? { config.vault.path.map { URL(fileURLWithPath: $0, isDirectory: true) } }
}

public enum RawNoteVerdict: Equatable, Sendable {
    case passed
    /// raw_output_path か raw_output_sha256 が NULL
    case notRecorded
    /// VaultCheck が .available でない（空の Vault に騙されない。DEL-06 / ND-36）
    case vaultUnavailable
    /// 落ちた規則（NoteVerification.failedRules。"RN-1" …）
    case failed([String])
}

/// 判定だけ（DB を書かない・ログを出さない）。要約（Daily ノート・解析）の成否と兄弟の Part の進み具合は条件にしない（DEL-04）。
public enum DeletionPolicy {
    /// 共通の同定 AND（根拠 A OR 根拠 B）。|| を共通項の外へ出してはならない（出すと根拠 B がロックも番犬も通らずに真になる）。
    public static func canDeleteSource(_ c: DeletionCandidate, _ ctx: DeletionContext) -> Bool {
        deletionIsIdentified(c, ctx)
            && (textIsPreserved(c.part, c.session, c.parts, ctx) || nothingToPreserve(c, ctx))
    }

    /// ロック・番犬・対象の同定。根拠 A と B の両方が必ず通る共通項。
    public static func deletionIsIdentified(_ c: DeletionCandidate, _ ctx: DeletionContext) -> Bool {
        ctx.locks.allReleased(for: c.part.deviceID)
            && sameKey(c.part.sessionKey, c.session.sessionKey)
            && c.parts.count >= 1  // 番犬: 空集合で真にしない（DEL-03 / CR-09）
            && c.part.sourcePath != nil
            && c.part.sourcePath?.isEmpty == false  // 番犬: "" はボリュームのルートを指す
            && preIdentityCheck(c.part, ctx)
    }

    /// 根拠 A: テキストが 2 か所に在る（Vault の Raw ノートと transcripts/parts/）。DB の status を信用しない（PR-12）。
    public static func textIsPreserved(
        _ part: RecordingRow, _ session: SessionRow, _ parts: [RecordingRow], _ ctx: DeletionContext
    ) -> Bool {
        session.rawOutputPath != nil
            && verifyRawNote(session, parts, ctx) == .passed
            && frontmatterKeys(session.rawOutputPath, ctx).contains(where: { sameKey($0, part.partkey) })
            && PartStates.deletable.contains(part.status)
            && part.transcriptPath != nil
            && partTranscriptIsValid(part, ctx)
    }

    /// 根拠 B: 保全すべき本文が無い（SKIPPED のまま。遷移させない。SM-20）。
    public static func nothingToPreserve(_ c: DeletionCandidate, _ ctx: DeletionContext) -> Bool {
        ctx.config.cleanup.deleteSkippedSource == true
            && c.part.status == .skipped
            && SkipReasons.deletable.contains(where: { $0 == c.part.errorCode })
            && skipReasonIsBacked(c, ctx)
    }

    /// 理由ごとの「本文が無い」根拠。表に無い理由は消さない側（SOURCE_MISSING も）。双子には同定を要求しない。
    public static func skipReasonIsBacked(_ c: DeletionCandidate, _ ctx: DeletionContext) -> Bool {
        switch c.part.errorCode {
        case .noSpeechDetected:
            return partTranscriptIsValid(c.part, ctx)
        case .duplicateContent:
            guard let twinKey = c.part.duplicateOf, let twin = c.twin, sameKey(twin.part.partkey, twinKey),
                !sameKey(twin.part.partkey, c.part.partkey), sameKey(twin.part.sessionKey, twin.session.sessionKey)
            else { return false }
            return textIsPreserved(twin.part, twin.session, twin.parts, ctx)
        default:
            return false
        }
    }

    /// PLAN §8.9.5（voicedock cleaner.py:351-390 ＋ 実ファイルへの検証）。安いものを先に、デバイスに触れるのは最後。
    /// DEL-12: size と mtime は DB の値（デバイス上の原本の値）。inbox のコピーを stat しない。
    public static func preIdentityCheck(_ part: RecordingRow, _ ctx: DeletionContext) -> Bool {
        // 1.
        guard let relpath = part.sourcePath, !relpath.isEmpty else { return false }
        // 2.
        guard RelPath.isSafe(relpath) else { return false }
        // 3. 鍵と実際に消すパスが一致すること（RV-05 と同じ）
        guard let made = try? PartKey.make(deviceID: part.deviceID, relpath: relpath), sameKey(made, part.partkey)
        else { return false }
        // 4. いま在ること（DEL-20 の新鮮さは呼び手が確かめる）
        guard let observation = ctx.snapshot?.devices[part.deviceID],
            observation.relpaths.contains(where: { sameKey($0, relpath) })
        else { return false }
        // 5.
        guard let size = part.sourceSize, let mtime = part.sourceMtime else { return false }
        // 6.
        guard let volumesRoot = ctx.locks.volumesRoot else { return false }
        // 7.
        guard case .opened(let volume) = ctx.volumeOpener.open(volumesRoot: volumesRoot, deviceID: part.deviceID)
        else { return false }
        // 8. snapshot の観測に加えて同じ fd の fstatfs でも確かめる二重確認（PLAN §4.6）
        guard volume.readOnly == false else { return false }
        // 9. body では何もしない（reaper は unlink の直前に同じ検証を独立にやり直す。DEL-26）
        let verified = TargetIdentity.withVerifiedTarget(
            volume: volume, relpath: relpath, expectedSize: size, expectedMtime: mtime
        ) { _ in () }
        switch verified {
        case .success: return true
        case .failure: return false
        }
    }

    /// PLAN §8.7 の期待値。書き込み直後の検証と同じ NoteVerifier.verify を呼ぶ。
    public static func verifyRawNote(_ session: SessionRow, _ parts: [RecordingRow], _ ctx: DeletionContext)
        -> RawNoteVerdict
    {
        // 1.
        guard let relative = session.rawOutputPath, let sha = session.rawOutputSHA256 else { return .notRecorded }
        // 2.
        guard VaultCheck.evaluate(path: ctx.config.vault.path, marker: ctx.config.vault.marker).isAvailable,
            let vault = ctx.vaultRoot
        else { return .vaultUnavailable }
        // 3. 書き手と同じ関数で Part 集合を作る（§9.1 原則 2）
        let expected = Set(
            parts.filter {
                RawNoteMembership.isMember(status: $0.status, transcriptReadable: partTranscriptIsValid($0, ctx))
            }
            .map(\.partkey))
        // 4. summaryHeading は Raw では使われない
        let v = NoteVerifier.verify(
            url: vault.appendingPathComponent(relative, isDirectory: false), kind: .raw,
            sessionKey: session.sessionKey, expectedSHA256: sha, expectedKeys: expected, summaryHeading: "")
        // 5.
        return v.passed ? .passed : .failed(v.failedRules)
    }

    /// voicedock notes.py:194-211。読めない・UTF-8 でない・frontmatter が無い・配列でない → []
    public static func frontmatterKeys(_ rawOutputPath: String?, _ ctx: DeletionContext) -> [String] {
        guard let rawOutputPath, let vault = ctx.vaultRoot else { return [] }
        return Frontmatter.recordingKeys(ofFile: vault.appendingPathComponent(rawOutputPath, isDirectory: false))
    }

    /// 実ファイルだけを根拠にする（transcript_path 列を見ない。voicedock cleaner.py:332-350）。§8.4 の合格条件
    public static func partTranscriptIsValid(_ part: RecordingRow, _ ctx: DeletionContext) -> Bool {
        let url = ctx.layout.transcript(slug: KeySlug.of(part.partkey))
        guard let data = try? Data(contentsOf: url) else { return false }
        return PartTranscriptCodec.decode(data) != nil
    }

    /// 鍵の照合（スカラー列の一致。00-api-map §0）。どちらかが nil なら偽
    static func sameKey(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return PyText.scalarsEqual(a, b)
    }
}
