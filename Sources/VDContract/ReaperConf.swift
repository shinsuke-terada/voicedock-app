// bin/reaper.conf の書式（PLAN §8.9.4）。アプリの有効化フローと reaper が同じ関数で読み書きする。
import Darwin
import Foundation

public struct ReaperConf: Equatable, Sendable {
    /// 常に Contract.reaperConfSchema
    public let schema: Int
    public let deleteSourceAudio: Bool
    /// 既定 Contract.volumesRoot
    public let volumesRoot: String

    /// schema = 1
    public init(deleteSourceAudio: Bool, volumesRoot: String = Contract.volumesRoot) {
        self.schema = Contract.reaperConfSchema
        self.deleteSourceAudio = deleteSourceAudio
        self.volumesRoot = volumesRoot
    }

    public static let keySchema = "SCHEMA"
    public static let keyDeleteSourceAudio = "DELETE_SOURCE_AUDIO"
    public static let keyVolumesRoot = "VOLUMES_ROOT"
    public static let linePattern = #"^[A-Z_]+=[^[:space:]]*$"#

    /// fail-closed。最初に当たった誤りを返す。
    public static func parse(_ data: Data) -> Result<ReaperConf, ReaperConfError> {
        if data.count > Contract.maxRequestBytes { return .failure(.tooLarge) }
        guard let text = String(data: data, encoding: .utf8) else { return .failure(.unreadable) }
        let known: Set<String> = [keySchema, keyDeleteSourceAudio, keyVolumesRoot]
        var values: [String: String] = [:]
        for (index, lineSub) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(lineSub)
            if line.isEmpty { continue }
            if line.hasPrefix("#") { continue }
            guard PatternMatch.wholeMatch(linePattern, line) != nil, let equal = line.firstIndex(of: "=") else {
                return .failure(.badLine(index + 1))
            }
            let key = String(line[..<equal])
            let value = String(line[line.index(after: equal)...])
            guard known.contains(key) else { return .failure(.unknownKey(key)) }
            guard values[key] == nil else { return .failure(.duplicateKey(key)) }
            values[key] = value
        }
        guard let schema = values[keySchema] else { return .failure(.missingKey(keySchema)) }
        guard schema == "1" else { return .failure(.badValue(keySchema)) }
        guard let delete = values[keyDeleteSourceAudio] else { return .failure(.missingKey(keyDeleteSourceAudio)) }
        let deleteSourceAudio: Bool
        switch delete {
        case "true": deleteSourceAudio = true
        case "false": deleteSourceAudio = false
        default: return .failure(.badValue(keyDeleteSourceAudio))
        }
        var volumesRoot = Contract.volumesRoot
        if let root = values[keyVolumesRoot] {
            guard root.hasPrefix("/") else { return .failure(.badValue(keyVolumesRoot)) }
            volumesRoot = root
        }
        return .success(ReaperConf(deleteSourceAudio: deleteSourceAudio, volumesRoot: volumesRoot))
    }

    /// 書き込みは呼び手が `AtomicFile.write(_, to:, permissions: 0o644)` で行う（このファイルは書かない）。
    public func render() -> Data {
        let flag = deleteSourceAudio ? "true" : "false"
        let text = "SCHEMA=1\nDELETE_SOURCE_AUDIO=\(flag)\nVOLUMES_ROOT=\(volumesRoot)\n"
        return Data(text.utf8)
    }

    /// symlink を辿らずに開き、通常ファイルで 64 KiB 以下のときだけ、fd を閉じてから parse する。どの経路でも fd を閉じる。
    /// `O_NONBLOCK` は FIFO を置かれても開くところで止まらないため（fstat で通常ファイルでないと分かる。
    /// 通常ファイルの読み取りには影響しない。F-73）
    public static func observe(at url: URL) -> ReaperConfObservation {
        let fd = open(url.path(percentEncoded: false), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            let code = errno
            if code == ENOENT { return .missing }
            if code == ELOOP { return .invalid(.notRegularFile) }
            return .invalid(.unreadable)
        }
        let read = readRegularFile(fd: fd)
        close(fd)
        switch read {
        case .failure(let error):
            return .invalid(error)
        case .success(let data):
            switch parse(data) {
            case .success(let conf): return .valid(conf)
            case .failure(let error): return .invalid(error)
            }
        }
    }

    /// fstat で通常ファイルかつ 64 KiB 以下を確かめてから全部読む（fd は閉じない。閉じるのは呼び手）。
    private static func readRegularFile(fd: Int32) -> Result<Data, ReaperConfError> {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .failure(.unreadable) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .failure(.notRegularFile) }
        guard info.st_size <= Contract.maxRequestBytes else { return .failure(.tooLarge) }
        switch PosixIO.readAll(fd: fd, limit: Contract.maxRequestBytes + 1) {
        case .failure: return .failure(.unreadable)
        case .success(let data): return .success(data)
        }
    }
}

public enum ReaperConfObservation: Equatable, Sendable {
    case missing
    case invalid(ReaperConfError)
    case valid(ReaperConf)
}

public enum ReaperConfError: Error, Equatable, Sendable {
    /// 開けない（ENOENT 以外）・読めない・UTF-8 でない
    case unreadable
    /// 64 KiB（Contract.maxRequestBytes）超
    case tooLarge
    /// symlink（O_NOFOLLOW で ELOOP）・通常ファイルでない
    case notRegularFile
    /// 行番号（1 始まり）の行が linePattern に一致しない
    case badLine(Int)
    case unknownKey(String)
    case duplicateKey(String)
    case missingKey(String)
    /// 引数はキー名
    case badValue(String)
}
