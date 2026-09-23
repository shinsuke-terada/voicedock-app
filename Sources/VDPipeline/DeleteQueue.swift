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

/// queue/delete と queue/result の名前の並び（F-79。どちらも names(in:) の順）。
struct QueueListing: Equatable, Sendable {
    let requests: [String]
    let results: [String]
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

    /// 読める要求（ContractJSON で読めたもの）の device_id を names(in: queueDelete) の順に（重複を除かない）。
    /// 読めない要求は数えない。無ければ []（F-79。PLAN §8.9.6。reaper を起動するかの判定に使う）
    static func requestedDeviceIDs(layout: HomeLayout) -> [String] {
        names(in: layout.queueDelete).compactMap { name in
            let url = layout.queueDelete.appendingPathComponent(name, isDirectory: false)
            guard let data = readSmallFile(url), case .success(let r) = ContractJSON.decodeRequest(data) else {
                return nil
            }
            return r.deviceID
        }
    }

    /// queue/delete と queue/result の名前の並び（F-79。PLAN §8.9.6。reaper の実行の前後で比べ、何か処理されたかを見る）
    static func listing(layout: HomeLayout) -> QueueListing {
        QueueListing(requests: names(in: layout.queueDelete), results: names(in: layout.queueResult))
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

    /// 取り下げの後にこの Part の要求が queue/delete に残っているか（F-74。PLAN §8.9.7）:
    /// `<requestID>.json` が在る（読めなくても。requestID が RequestID の形のときだけ名前で見る）か、読めて partkey が一致する要求が在る
    static func hasRequest(partkey: String, requestID: String, layout: HomeLayout) -> Bool {
        var st = stat()
        if RequestID.isValid(requestID),
            lstat(requestURL(requestID, layout: layout).path(percentEncoded: false), &st) == 0
        {
            return true
        }
        return names(in: layout.queueDelete).contains { name in
            let url = layout.queueDelete.appendingPathComponent(name, isDirectory: false)
            guard let data = readSmallFile(url), case .success(let r) = ContractJSON.decodeRequest(data) else {
                return false
            }
            return DeletionPolicy.sameKey(r.partkey, partkey)
        }
    }

    /// `queue/result/<requestID>.json`（lstat で在るときだけ。読めなければ result が nil）。
    /// requestID が RequestID の形でなければ nil（名前を組まない。F-74。PLAN §8.9.7）
    static func result(requestID: String, layout: HomeLayout) -> QueuedResult? {
        guard RequestID.isValid(requestID) else { return nil }
        let url = resultURL(requestID, layout: layout)
        var st = stat()
        guard lstat(url.path(percentEncoded: false), &st) == 0 else { return nil }
        return QueuedResult(url: url, result: readSmallFile(url).flatMap { try? ContractJSON.decodeResult($0).get() })
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

extension DeleteQueue {
    /// 無効化のときに `queue/delete` の要求を全部取り下げる（PLAN §8.9.8）。
    /// `.` で始まらない `*.json` を全部消す（中身は読まない。読めない要求も消す）。
    /// 結果（`queue/result`）は消さない。DB の `delete_request_id` は触らない（RequestExpirer が期限で取り下げる）。
    /// 戻り値は (消した数, 消せなかった数)
    static func withdrawAllRequests(layout: HomeLayout) -> (removed: Int, failed: Int) {
        var removed = 0
        var failed = 0
        for name in names(in: layout.queueDelete) {
            let url = layout.queueDelete.appendingPathComponent(name)
            if (try? SafeUnlink.remove(url, under: .queueDelete, layout: layout)) != nil {
                removed += 1
            } else {
                failed += 1
            }
        }
        return (removed, failed)
    }
}
