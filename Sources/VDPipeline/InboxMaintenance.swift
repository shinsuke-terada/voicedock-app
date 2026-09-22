// inbox の孤児の削除（起動時）と取り残しの集計（DR-15・状態の詳細）。PLAN §5.3・§8.12。
import Darwin
import Foundation
import VDContract
import VDCore
import VDStore

/// inbox の孤児の削除と取り残しの集計。同期。呼び手が `BlockingIO.run` で包む。
struct InboxMaintenance {
    let store: Store
    let layout: HomeLayout
    let log: AppLog

    /// 走査の結果（.partial の全部と、partkey ごとの _orig.wav）。
    struct Walk {
        var partials: [URL] = []
        var origs: [String: (url: URL, size: Int64)] = [:]
    }

    /// DB に行の無い _orig.wav と、すべての .partial を消す。消せた数を返す。
    func removeOrphans() throws -> Int {
        let found = walk()
        let known = try store.knownPartkeys(Array(found.origs.keys))
        var targets = found.partials
        for (pk, entry) in found.origs where !known.contains(pk) {
            targets.append(entry.url)
        }
        targets.sort {
            $0.path(percentEncoded: false).unicodeScalars.map(\.value)
                .lexicographicallyPrecedes($1.path(percentEncoded: false).unicodeScalars.map(\.value))
        }
        var removed = 0
        for url in targets {
            do {
                try SafeUnlink.remove(url, under: .inbox, layout: layout, missingOK: true)
                removed += 1
            } catch {
                let shown = layout.relativePath(of: url) ?? url.path(percentEncoded: false)
                log.warning(
                    .configWarning,
                    [(.rule, "inbox"), (.message, .string("\(shown) を消せません: \(ErrorText.describe(error))"))])
            }
        }
        return removed
    }

    /// PartStates.inboxLeftover の Part の _orig.wav の件数とバイト数（処理待ちは数えない）。
    func leftovers() throws -> (count: Int, bytes: Int64) {
        let keys = Set(try store.partkeys(statuses: PartStates.inboxLeftover))
        var count = 0
        var bytes: Int64 = 0
        for (pk, entry) in walk().origs where keys.contains(pk) {
            count += 1
            bytes += entry.size
        }
        return (count, bytes)
    }

    /// inbox の直下のディレクトリ（device_id）ごとに中を回る。symlink は辿らない。
    func walk() -> Walk {
        var result = Walk()
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: layout.inbox.path(percentEncoded: false)) else {
            return result
        }
        for d in names {
            let deviceDir = layout.inbox.appendingPathComponent(d, isDirectory: true)
            var info = stat()
            guard lstat(deviceDir.path(percentEncoded: false), &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR
            else { continue }
            let baseCount = deviceDir.standardizedFileURL.pathComponents.count
            guard
                let items = manager.enumerator(
                    at: deviceDir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                    options: [])
            else { continue }
            for case let url as URL in items {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                if values?.isSymbolicLink == true || values?.isRegularFile != true { continue }
                let name = url.lastPathComponent
                let scalars = Array(name.unicodeScalars)
                if scalars.first == "." && scalars.suffix(8).elementsEqual(".partial".unicodeScalars) {
                    result.partials.append(url)
                    continue
                }
                guard RecordingName.parseFile(name)?.isOrig == true else { continue }
                let parts = Array(url.standardizedFileURL.pathComponents.dropFirst(baseCount))
                let relpath = RelPath.join(parts)
                guard let pk = try? PartKey.make(deviceID: d, relpath: relpath) else { continue }
                result.origs[pk] = (url, Int64(values?.fileSize ?? 0))
            }
        }
        return result
    }
}
