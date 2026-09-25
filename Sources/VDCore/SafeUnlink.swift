// 決まったルートの配下だけを消す安全な削除（PLAN §9.2。PT-01 の許可場所）。デバイスの原本はここでは消さない。
import Darwin
import Foundation
import VDContract

public enum SafeUnlinkRoot: Sendable, Equatable {
    case inbox, staging, transcripts, analysis, queueDelete, queueResult, models, run
    /// <HOME> 直下の DB の 3 つのファイルだけ（データの初期化。F-95）
    case database
    case vaultTmp(vault: URL)

    /// `database` で消してよい名前（<HOME> 直下のこの 3 つだけ。F-95）
    public static let databaseFileNames = ["voicedock.sqlite", "voicedock.sqlite-wal", "voicedock.sqlite-shm"]

    /// ルートのディレクトリ。
    func directory(_ layout: HomeLayout) -> URL {
        switch self {
        case .inbox: return layout.inbox
        case .staging: return layout.staging
        case .transcripts: return layout.transcriptsParts
        case .analysis: return layout.analysis
        case .queueDelete: return layout.queueDelete
        case .queueResult: return layout.queueResult
        case .models: return layout.modelsDirectory
        case .run: return layout.runDirectory
        case .database: return layout.root
        case .vaultTmp(let vault): return vault
        }
    }
}

public enum SafeUnlinkError: Error, Equatable, Sendable {
    case notAbsolute, containsDotDot, rootUnresolvable, outsideRoot, nameNotAllowed, notFound
    case isSymlink, notRegularFile, notDirectory
    case unlinkFailed(errno: Int32)
    case rmdirFailed(errno: Int32)
}

public enum SafeUnlink {
    /// ルート配下の通常ファイルを 1 つ消す。symlink はリンクも消さない。検査の順は PLAN §9.2。
    public static func remove(
        _ target: URL, under root: SafeUnlinkRoot, layout: HomeLayout, missingOK: Bool = true
    ) throws(SafeUnlinkError) {
        guard let located = try locate(target, under: root, layout: layout, missingOK: missingOK) else { return }
        switch root {
        case .queueDelete, .queueResult:
            guard located.parentIsRoot, located.name.hasSuffix(".json") else { throw .nameNotAllowed }
        case .database:
            guard located.parentIsRoot, SafeUnlinkRoot.databaseFileNames.contains(located.name) else {
                throw .nameNotAllowed
            }
        case .vaultTmp:
            let name = located.name
            guard name.hasPrefix("."), name.hasSuffix(".tmp"), TextLimit.scalarCount(name) > 5 else {
                throw .nameNotAllowed
            }
        default:
            break
        }
        var info = stat()
        guard lstat(located.path, &info) == 0 else {
            let code = errno
            if code == ENOENT {
                if missingOK { return }
                throw .notFound
            }
            throw .unlinkFailed(errno: code)
        }
        let type = info.st_mode & S_IFMT
        guard type != S_IFLNK else { throw .isSymlink }
        guard type == S_IFREG else { throw .notRegularFile }
        guard unlink(located.path) == 0 else {
            let code = errno
            if code == ENOENT {
                if missingOK { return }
                throw .notFound
            }
            throw .unlinkFailed(errno: code)
        }
    }

    /// ルート配下の空のディレクトリを消す。中身があれば何もしない。ルートそのものは消させない。
    public static func removeEmptyDirectory(
        _ target: URL, under root: SafeUnlinkRoot, layout: HomeLayout
    ) throws(SafeUnlinkError) {
        guard let located = try locate(target, under: root, layout: layout, missingOK: true) else { return }
        var info = stat()
        guard lstat(located.path, &info) == 0 else {
            let code = errno
            if code == ENOENT { return }
            throw .rmdirFailed(errno: code)
        }
        let type = info.st_mode & S_IFMT
        guard type != S_IFLNK else { throw .isSymlink }
        guard type == S_IFDIR else { throw .notDirectory }
        guard rmdir(located.path) == 0 else {
            let code = errno
            if code == ENOTEMPTY || code == EEXIST || code == ENOENT { return }
            throw .rmdirFailed(errno: code)
        }
    }

    /// 検査 1〜6 を通った対象（親の realpath ＋ "/" ＋ 名前）。親が無く missingOK なら nil。
    struct Located {
        let path: String
        let name: String
        let parentIsRoot: Bool
    }

    static func locate(
        _ target: URL, under root: SafeUnlinkRoot, layout: HomeLayout, missingOK: Bool
    ) throws(SafeUnlinkError) -> Located? {
        let targetPath = target.path(percentEncoded: false)
        // 1. 絶対パスだけ
        guard targetPath.hasPrefix("/") else { throw .notAbsolute }
        // 2. `..` を含まない。要素は Unicode スカラーの "/"（UTF-8 の 0x2F。カーネルと同じ区切り）で分ける。
        //    Character（書記素）で分けると "/" の直後の結合文字（U+0301 など）で区切りを見落とし、"a/../\u{301}b" の
        //    ".." を見逃す（F-81。RelPath と同じ。F-73）
        let components = targetPath.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.elementsEqual("..".unicodeScalars) }) else {
            throw .containsDotDot
        }
        // 3. ルートの realpath
        guard case .success(let rootReal) = realPath(root.directory(layout).path(percentEncoded: false)) else {
            throw .rootUnresolvable
        }
        // 4. 親の realpath
        let parentReal: String
        switch realPath(target.deletingLastPathComponent().path(percentEncoded: false)) {
        case .success(let resolved):
            parentReal = resolved
        case .failure(let code):
            guard code == ENOENT else { throw .outsideRoot }
            if missingOK { return nil }
            throw .notFound
        }
        // 5. 親がルートと等しいか、ルート + "/" で始まる（接頭辞だけ一致する兄弟は配下ではない）
        let parentIsRoot = parentReal == rootReal
        guard parentIsRoot || parentReal.hasPrefix(rootReal + "/") else { throw .outsideRoot }
        // 6. 名前
        let name = target.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { throw .nameNotAllowed }
        return Located(path: parentReal + "/" + name, name: name, parentIsRoot: parentIsRoot)
    }

    /// realpath(3) の結果。
    enum Resolved {
        case success(String)
        case failure(Int32)
    }

    /// realpath(3)。失敗なら errno。
    static func realPath(_ path: String) -> Resolved {
        guard let resolved = Darwin.realpath(path, nil) else { return .failure(errno) }
        defer { free(resolved) }
        return .success(String(cString: resolved))
    }
}
