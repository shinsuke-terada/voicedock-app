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
        if let existing, usable(existing) {
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

    /// 上書きしてよいか（§8.8）。session_key が一致し、ノートに載った鍵が全部この Session の Part のもののときだけ真。
    /// 読めないノート・voicedock が書いたノート・利用者が作ったノートは上書きしない。
    public static func mayOverwrite(_ url: URL, sessionKey: String, ownedPartkeys: Set<String>, kind: NoteKind) -> Bool
    {
        guard let data = try? Data(contentsOf: url) else { return false }
        guard let text = String(validating: data, as: UTF8.self) else { return false }
        guard let doc = Frontmatter.parse(text) else { return false }
        guard (doc[Frontmatter.keySessionKey] as? String).map({ PyText.scalarsEqual($0, sessionKey) }) ?? false else {
            return false
        }
        var keys = Frontmatter.stringList(doc, Frontmatter.keyRecordingKeys)
        if kind == .daily {
            keys += Frontmatter.stringList(doc, Frontmatter.keyFailedParts)
            keys += Frontmatter.stringList(doc, Frontmatter.keySkippedParts)
        }
        // 鍵はスカラー列で照合する（00-api-map §0）
        return NoteVerifier.scalarSet(keys).isSubset(of: NoteVerifier.scalarSet(ownedPartkeys))
    }

    /// symlink を辿る。壊れた symlink は「無い」（rename が symlink 自体を置き換える。voicedock どおり）
    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return stat(url.path(percentEncoded: false), &st) == 0
    }
}
