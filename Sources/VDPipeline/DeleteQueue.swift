// queue/delete と queue/result のファイルの読み書き（PLAN §4.4・§8.9.6・§8.9.7）。要求を書くのは RequestWriter 経由だけ（PR-09）。
import Darwin
import Foundation
import VDContract
import VDCore

enum DeleteQueueError: Error, Equatable {
    case encode(ContractEncodeError)
    case write(AtomicFileError)
}

struct QueuedResult: Sendable {
    let url: URL
    /// ContractJSON で読めなければ nil（残す）
    let result: DeleteResult?
}

/// queue/delete と queue/result の読み書き。取り下げ・捨てるの失敗は記録しない（残ったものは DEL-08 と冪等な回収で決着する）。
enum DeleteQueue {
    /// `.` で始まらない `*.json` の名前を UTF-8 のバイト順に。ディレクトリが読めなければ []
    static func names(in directory: URL) -> [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return
            all
            .filter { !$0.hasPrefix(".") && $0.hasSuffix(".json") }
            .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    /// queue/delete/<id>.json
    static func requestURL(_ requestID: String, layout: HomeLayout) -> URL {
        layout.queueDelete.appendingPathComponent(requestID + ".json", isDirectory: false)
    }

    /// queue/result/<id>.json
    static func resultURL(_ requestID: String, layout: HomeLayout) -> URL {
        layout.queueResult.appendingPathComponent(requestID + ".json", isDirectory: false)
    }

    static func write(_ request: DeleteRequest, layout: HomeLayout) throws(DeleteQueueError) {
        let data: Data
        do {
            data = try ContractJSON.encode(request)
        } catch {
            throw .encode(error)
        }
        do {
            try AtomicFile.write(data, to: requestURL(request.requestID, layout: layout), permissions: 0o644)
        } catch {
            throw .write(error)
        }
    }

    /// names(in: queueDelete) が空でない
    static func hasPendingRequests(layout: HomeLayout) -> Bool {
        !names(in: layout.queueDelete).isEmpty
    }

    /// names(in: queueResult) の順
    static func results(layout: HomeLayout) -> [QueuedResult] {
        names(in: layout.queueResult).map { name in
            let url = layout.queueResult.appendingPathComponent(name, isDirectory: false)
            let result = readSmallFile(url).flatMap { try? ContractJSON.decodeResult($0).get() }
            return QueuedResult(url: url, result: result)
        }
    }

    /// partkey がこの Part の要求を全部取り下げる。読めない要求は残す。消した数
    static func withdrawRequests(partkey: String, layout: HomeLayout) -> Int {
        var removed = 0
        for name in names(in: layout.queueDelete) {
            let url = layout.queueDelete.appendingPathComponent(name, isDirectory: false)
            guard let data = readSmallFile(url), case .success(let r) = ContractJSON.decodeRequest(data),
                DeletionPolicy.sameKey(r.partkey, partkey)
            else { continue }
            if (try? SafeUnlink.remove(url, under: .queueDelete, layout: layout)) != nil { removed += 1 }
        }
        return removed
    }

    /// 同じく結果
    static func withdrawResults(partkey: String, layout: HomeLayout) -> Int {
        var removed = 0
        for name in names(in: layout.queueResult) {
            let url = layout.queueResult.appendingPathComponent(name, isDirectory: false)
            guard let data = readSmallFile(url), case .success(let r) = ContractJSON.decodeResult(data),
                DeletionPolicy.sameKey(r.partkey, partkey)
            else { continue }
            if (try? SafeUnlink.remove(url, under: .queueResult, layout: layout)) != nil { removed += 1 }
        }
        return removed
    }

    /// 結果を捨てる（SafeUnlink.remove(url, under: .queueResult)）
    static func discard(_ url: URL, layout: HomeLayout) {
        try? SafeUnlink.remove(url, under: .queueResult, layout: layout)
    }

    /// lstat が通常ファイルで st_size <= Contract.maxRequestBytes のときだけ読む。それ以外・失敗は nil
    static func readSmallFile(_ url: URL) -> Data? {
        var st = stat()
        guard lstat(url.path(percentEncoded: false), &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
            st.st_size <= Contract.maxRequestBytes
        else { return nil }
        guard let data = try? Data(contentsOf: url), data.count <= Contract.maxRequestBytes else { return nil }
        return data
    }
}
