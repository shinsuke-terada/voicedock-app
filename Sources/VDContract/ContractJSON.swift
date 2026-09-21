// 削除要求と結果の JSON の符号化と厳格な復号（PLAN §4.4）。アプリと reaper が共有する。
import Foundation

public enum ContractJSON {
    public static let requestKeys: Set<String> = [
        "schema", "request_id", "created_at", "device_id", "partkey", "session_key", "targets",
    ]
    public static let targetKeys: Set<String> = ["relpath", "size", "mtime"]
    public static let resultKeys: Set<String> = [
        "schema", "request_id", "completed_at", "reaper_version", "device_id", "partkey", "status", "detail",
    ]

    /// 整形・キーの辞書順・"/" をエスケープしない。末尾に改行を 1 バイト足す。
    public static func encode(_ r: DeleteRequest) throws(ContractEncodeError) -> Data {
        let dto = RequestDTO(
            schema: r.schema, requestID: r.requestID, createdAt: r.createdAt, deviceID: r.deviceID,
            partkey: r.partkey, sessionKey: r.sessionKey,
            targets: [TargetDTO(relpath: r.target.relpath, size: r.target.size, mtime: r.target.mtime)])
        return try encodeDTO(dto)
    }

    /// 整形・キーの辞書順・"/" をエスケープしない。末尾に改行を 1 バイト足す。
    public static func encode(_ r: DeleteResult) throws(ContractEncodeError) -> Data {
        let dto = ResultDTO(
            schema: r.schema, requestID: r.requestID, completedAt: r.completedAt, reaperVersion: r.reaperVersion,
            deviceID: r.deviceID, partkey: r.partkey, status: r.status.rawValue, detail: r.detail)
        return try encodeDTO(dto)
    }

    /// 厳格に復号する。最初に当たった誤りを返す。
    public static func decodeRequest(_ data: Data) -> Result<DeleteRequest, ContractDecodeError> {
        let dict: [String: Any]
        switch topLevelObject(data, keys: requestKeys) {
        case .failure(let error): return .failure(error)
        case .success(let value): dict = value
        }
        if let error = checkSchema(dict["schema"]) { return .failure(error) }
        var strings: [String: String] = [:]
        for key in ["request_id", "created_at", "device_id", "partkey", "session_key"] {
            guard let value = dict[key] as? String else { return .failure(.wrongType(key)) }
            strings[key] = value
        }
        guard let targets = dict["targets"] as? [Any], targets.count == 1,
            let target = targets[0] as? [String: Any], Set(target.keys) == targetKeys
        else { return .failure(.badTargets) }
        guard let relpath = target["relpath"] as? String else { return .failure(.wrongType("targets.relpath")) }
        guard let size = target["size"] as? NSNumber, !isBoolean(size), !CFNumberIsFloatType(size),
            size.int64Value >= 0
        else { return .failure(.wrongType("targets.size")) }
        guard let mtime = target["mtime"] as? NSNumber, !isBoolean(mtime), mtime.doubleValue.isFinite else {
            return .failure(.wrongType("targets.mtime"))
        }
        return .success(
            DeleteRequest(
                schema: Contract.requestSchema, requestID: strings["request_id"] ?? "",
                createdAt: strings["created_at"] ?? "", deviceID: strings["device_id"] ?? "",
                partkey: strings["partkey"] ?? "", sessionKey: strings["session_key"] ?? "",
                target: DeleteTarget(relpath: relpath, size: size.int64Value, mtime: mtime.doubleValue)))
    }

    /// 厳格に復号する。最初に当たった誤りを返す。
    public static func decodeResult(_ data: Data) -> Result<DeleteResult, ContractDecodeError> {
        let dict: [String: Any]
        switch topLevelObject(data, keys: resultKeys) {
        case .failure(let error): return .failure(error)
        case .success(let value): dict = value
        }
        if let error = checkSchema(dict["schema"]) { return .failure(error) }
        var strings: [String: String] = [:]
        for key in ["request_id", "completed_at", "reaper_version", "device_id", "partkey", "status", "detail"] {
            guard let value = dict[key] as? String else { return .failure(.wrongType(key)) }
            strings[key] = value
        }
        guard let status = DeleteResultStatus(rawValue: strings["status"] ?? "") else {
            return .failure(.wrongType("status"))
        }
        return .success(
            DeleteResult(
                schema: Contract.resultSchema, requestID: strings["request_id"] ?? "",
                completedAt: strings["completed_at"] ?? "", reaperVersion: strings["reaper_version"] ?? "",
                deviceID: strings["device_id"] ?? "", partkey: strings["partkey"] ?? "", status: status,
                detail: strings["detail"] ?? ""))
    }

    private static func encodeDTO<T: Encodable>(_ dto: T) throws(ContractEncodeError) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(dto) else { throw .nonFiniteNumber }
        data.append(0x0A)
        return data
    }

    /// UTF-8 で JSON のオブジェクトで、トップレベルのキー集合が keys と完全に一致すること。
    private static func topLevelObject(_ data: Data, keys: Set<String>) -> Result<[String: Any], ContractDecodeError> {
        guard String(data: data, encoding: .utf8) != nil else { return .failure(.notJSONObject) }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
            let dict = object as? [String: Any]
        else { return .failure(.notJSONObject) }
        guard Set(dict.keys) == keys else { return .failure(.keySetMismatch) }
        return .success(dict)
    }

    /// schema は真偽値でない NSNumber で、浮動小数の表記でない整数 1。
    private static func checkSchema(_ value: Any?) -> ContractDecodeError? {
        guard let n = value as? NSNumber, !isBoolean(n) else { return .wrongType("schema") }
        if CFNumberIsFloatType(n) || n.int64Value != 1 { return .badSchema }
        return nil
    }

    /// JSONSerialization の true / false も NSNumber なので、CFBoolean かどうかで弾く。
    private static func isBoolean(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }
}

public enum ContractEncodeError: Error, Equatable, Sendable {
    /// mtime が NaN / ±∞（JSONEncoder が符号化できない）
    case nonFiniteNumber
}

public enum ContractDecodeError: Error, Equatable, Sendable {
    /// UTF-8 でない・JSON でない・トップレベルがオブジェクトでない
    case notJSONObject
    /// トップレベルのキー集合が期待と完全一致しない
    case keySetMismatch
    /// 値の型が違う（引数はキーのパス。例 "schema"、"targets.size"）
    case wrongType(String)
    /// schema が整数 1 でない
    case badSchema
    /// targets が配列でない・要素数が 1 でない・要素のキー集合が違う
    case badTargets
}

struct RequestDTO: Codable {
    let schema: Int
    let requestID: String
    let createdAt: String
    let deviceID: String
    let partkey: String
    let sessionKey: String
    let targets: [TargetDTO]

    enum CodingKeys: String, CodingKey {
        case schema
        case requestID = "request_id"
        case createdAt = "created_at"
        case deviceID = "device_id"
        case partkey
        case sessionKey = "session_key"
        case targets
    }
}

struct TargetDTO: Codable {
    let relpath: String
    let size: Int64
    let mtime: Double
}

struct ResultDTO: Codable {
    let schema: Int
    let requestID: String
    let completedAt: String
    let reaperVersion: String
    let deviceID: String
    let partkey: String
    let status: String
    let detail: String

    enum CodingKeys: String, CodingKey {
        case schema
        case requestID = "request_id"
        case completedAt = "completed_at"
        case reaperVersion = "reaper_version"
        case deviceID = "device_id"
        case partkey
        case status
        case detail
    }
}
