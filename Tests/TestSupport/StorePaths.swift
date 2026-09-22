// テストの行を遷移表の辺だけで任意の状態へ進める（SQL で status を書かない。PT-05 の趣旨）。作り手 T-36。
import Foundation
import GRDB
import VDCore

@testable import VDStore

public struct StorePathError: Error, CustomStringConvertible {
    public let description: String

    init(_ description: String) {
        self.description = description
    }
}

public enum StorePaths {
    static let partMain: [PartStatus] = [
        .normalizing, .normalized, .transcribing, .transcribed, .rawWriting, .rawSaved,
    ]
    static let sessionMain: [SessionStatus] = [.ready, .merging, .merged, .analyzing, .analyzed, .writing, .saved]

    /// DISCOVERED から status までの経路（最初の DISCOVERED を含まない）
    public static func partPath(to status: PartStatus, errorCode: ErrorCode?) -> [PartStatus] {
        switch status {
        case .discovered:
            return []
        case .normalizing, .normalized, .transcribing, .transcribed, .rawWriting, .rawSaved:
            guard let index = partMain.firstIndex(of: status) else { return [] }
            return Array(partMain[...index])
        case .sourceDeleting:
            return partMain + [.sourceDeleting]
        case .sourceDeletePending:
            return partMain + [.sourceDeleting, .sourceDeletePending]
        case .completed:
            return partMain + [.completed]
        case .failed:
            return [.normalizing, .normalized, .transcribing, .failed]
        case .skipped:
            switch errorCode {
            case .sourceMissing: return [.skipped]
            case .duplicateContent: return [.normalizing, .skipped]
            default: return [.normalizing, .normalized, .transcribing, .skipped]
            }
        }
    }

    /// OPEN から status までの経路（最初の OPEN を含まない）
    public static func sessionPath(to status: SessionStatus) -> [SessionStatus] {
        switch status {
        case .open:
            return []
        case .ready, .merging, .merged, .analyzing, .analyzed, .writing, .saved:
            guard let index = sessionMain.firstIndex(of: status) else { return [] }
            return Array(sessionMain[...index])
        case .sourceDeleting:
            return sessionMain + [.sourceDeleting]
        case .sourceDeletePending:
            return sessionMain + [.sourceDeleting, .sourceDeletePending]
        case .cleanup:
            return sessionMain + [.cleanup]
        case .completed:
            return sessionMain + [.cleanup, .completed]
        case .failed:
            return [.ready, .merging, .failed]
        }
    }

    /// 今の状態から経路に沿って status まで。今の状態が経路に無ければ StorePathError。最後の辺にだけ errorCode を渡す
    public static func advancePart(
        _ store: Store, partkey: String, to status: PartStatus, errorCode: ErrorCode? = nil
    ) throws {
        guard let row = try store.recording(partkey) else { throw StorePathError("\(partkey) の行が無い") }
        let path = partPath(to: status, errorCode: errorCode)
        let start: Int
        if row.status == .discovered {
            start = 0
        } else {
            guard let index = path.firstIndex(of: row.status) else {
                throw StorePathError("\(row.status) から \(status) への経路が無い")
            }
            start = index + 1
        }
        var previous = row.status
        for index in path.indices where index >= start {
            let next = path[index]
            try store.recordPartTransition(
                partkey: partkey, from: previous, to: next, errorCode: index == path.count - 1 ? errorCode : nil)
            previous = next
        }
    }

    public static func advanceSession(_ store: Store, sessionKey: String, to status: SessionStatus) throws {
        guard let row = try store.session(sessionKey) else { throw StorePathError("\(sessionKey) の行が無い") }
        let path = sessionPath(to: status)
        let start: Int
        if row.status == .open {
            start = 0
        } else {
            guard let index = path.firstIndex(of: row.status) else {
                throw StorePathError("\(row.status) から \(status) への経路が無い")
            }
            start = index + 1
        }
        var previous = row.status
        for index in path.indices where index >= start {
            let next = path[index]
            try store.recordSessionTransition(sessionKey: sessionKey, from: previous, to: next)
            previous = next
        }
    }

    /// source_path を直接書き換える（RecordingField に無い列。ND-21 の nil と "" を作るためだけ）
    public static func setSourcePath(_ store: Store, partkey: String, _ value: String?) throws {
        try store.pool.write {
            try $0.execute(sql: "UPDATE recordings SET source_path = ? WHERE partkey = ?", arguments: [value, partkey])
        }
    }
}
