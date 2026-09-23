// 出力先の決定と既存ノートの扱い（PLAN §8.8 / X-11）。voicedock の「session_key が一致すれば誰のでも上書き」を、鍵の所有まで見る規則にした。
import Foundation
import VDCore

public enum OutputPathResolver {
    public static let maxSuffix = 99
    static let markdownSuffix = ".md"

    /// existing = DB の当該 Session の出力パスを Vault の URL に足したもの（無ければ nil）。
    /// ownedPartkeys = アプリの DB でこの Session に属する Part の partkey の全部（状態を問わない）。
    public static func resolve(
        folder: URL, baseName: String, existing: URL?, sessionKey: String,
        ownedPartkeys: Set<String>, kind: NoteKind
    ) -> Result<URL, StageFailure> {
        func usable(_ url: URL) -> Bool {
            !exists(url) || mayOverwrite(url, sessionKey: sessionKey, ownedPartkeys: ownedPartkeys, kind: kind)
        }
        // F-75: 親フォルダが無い DB の出力パスは使わない（folderTemplate を変えて古いフォルダを消した。書けば ENOENT が続く）
        if let existing, parentIsDirectory(existing), usable(existing) {
            return .success(existing)
        }
        for n in 1...maxSuffix {
            let name = n == 1 ? baseName + markdownSuffix : baseName + " (" + String(n) + ")" + markdownSuffix
            let candidate = folder.appendingPathComponent(name, isDirectory: false)
            if usable(candidate) {
                return .success(candidate)
            }
        }
        return .failure(
            StageFailure(
                kind == .raw ? .obsidianRawWriteFailed : .obsidianWriteFailed,
                "同名ファイルが多すぎます: " + baseName + markdownSuffix))
    }

    /// 上書きしてよいか（§8.8）。`type` が書こうとしている種類で（F-75）、session_key が一致し、
    /// ノートに載った鍵が全部この Session の Part のもののときだけ真。
    /// 読めないノート・voicedock が書いたノート・利用者が作ったノート・種類の違うノートは上書きしない。
    /// F-75: 鍵の列（`voicedock_recording_keys`。Daily は `voicedock_failed_parts` / `voicedock_skipped_parts` も）が
    /// 在るのに配列でない、または `voicedock_recording_keys` が無いノートも上書きしない（どの Part の本文が載っているか分からない）。
    public static func mayOverwrite(_ url: URL, sessionKey: String, ownedPartkeys: Set<String>, kind: NoteKind) -> Bool
    {
        guard let doc = frontmatter(of: url) else { return false }
        // F-75: Raw と Daily のフォルダが大文字小文字だけ違うと APFS では同じファイルになる。種類の違うノートを置き換えない
        guard (doc[Frontmatter.keyType] as? String).map({ PyText.scalarsEqual($0, noteType(kind)) }) ?? false else {
            return false
        }
        guard (doc[Frontmatter.keySessionKey] as? String).map({ PyText.scalarsEqual($0, sessionKey) }) ?? false else {
            return false
        }
        guard var keys = keyList(doc, Frontmatter.keyRecordingKeys) else { return false }
        if kind == .daily {
            for name in [Frontmatter.keyFailedParts, Frontmatter.keySkippedParts] where doc[name] != nil {
                guard let more = keyList(doc, name) else { return false }
                keys += more
            }
        }
        // 鍵はスカラー列で照合する（00-api-map §0）
        return NoteVerifier.scalarSet(keys).isSubset(of: NoteVerifier.scalarSet(ownedPartkeys))
    }

    /// F-75: url のノートを書き直すと消える鍵（§8.8）。ノートの `voicedock_recording_keys` のうち、
    /// protectedKeys に在って newKeys に無いもの（ノートの並び順・重複なし。スカラー列で照合）。
    /// 引数を Set<String> にしない（正準等価な 2 本がまとまり、片方の喪失を見逃す）。
    /// ファイルが無ければ空。在るのに読めない（UTF-8 でない・frontmatter が読めない・`voicedock_recording_keys` が
    /// 無いか配列でない）なら nil（呼び手は書かない）。
    public static func keysLostByOverwrite(_ url: URL, protectedKeys: [String], newKeys: [String]) -> [String]? {
        guard exists(url) else { return [] }
        guard let doc = frontmatter(of: url), let keys = keyList(doc, Frontmatter.keyRecordingKeys) else { return nil }
        let guarded = NoteVerifier.scalarSet(protectedKeys)
        let kept = NoteVerifier.scalarSet(newKeys)
        var seen: Set<[Unicode.Scalar]> = []
        var lost: [String] = []
        for key in keys {
            let scalars = Array(key.unicodeScalars)
            if guarded.contains(scalars) && !kept.contains(scalars) && seen.insert(scalars).inserted {
                lost.append(key)
            }
        }
        return lost
    }

    /// ノートの frontmatter。読めない・UTF-8 でない・frontmatter が読めなければ nil
    static func frontmatter(of url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let text = String(validating: data, as: UTF8.self) else { return nil }
        return Frontmatter.parse(text)
    }

    /// 鍵の列。doc[name] が配列なら各要素を文字列化したもの、無い・配列でなければ nil（`Frontmatter.stringList` は空にする）
    static func keyList(_ doc: [String: Any], _ name: String) -> [String]? {
        guard doc[name] is [Any] else { return nil }
        return Frontmatter.stringList(doc, name)
    }

    /// 書こうとしている種類の `type`（`voice-raw` / `voice-daily`）
    static func noteType(_ kind: NoteKind) -> String {
        kind == .raw ? RawNote.noteType : DailyNote.noteType
    }

    /// symlink を辿る。壊れた symlink は「無い」（rename が symlink 自体を置き換える。voicedock どおり）
    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return stat(url.path(percentEncoded: false), &st) == 0
    }

    /// 親が（symlink を辿って）ディレクトリか。親の URL は末尾に "/" が付くので、親がファイルなら stat が ENOTDIR で偽になる。
    /// S_IFDIR の確認は念のため（振る舞いでは落とせない。破壊による証明で確かめた）
    static func parentIsDirectory(_ url: URL) -> Bool {
        var st = stat()
        return stat(url.deletingLastPathComponent().path(percentEncoded: false), &st) == 0
            && (st.st_mode & S_IFMT) == S_IFDIR
    }
}
