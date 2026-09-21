// モデルカタログ（Resources/ModelCatalog.json）の型と読み込み（PLAN §8.10・§3.4）。不合格の項目は捨てて記録する（OPS-19）。
import Foundation

public enum ModelKind: String, Sendable, CaseIterable, Hashable {
    case whisper
    case vad
    case llm
}

public struct ModelEntry: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let file: String
    public let url: String
    public let sha256: String
    public let bytes: Int64
    public let license: String
    /// llm だけ（必須）。whisper / vad は nil
    public let minMemoryGB: Int?
    /// llm だけ（必須）。whisper / vad は nil
    public let verified: Bool?
}

public struct CatalogRejection: Equatable, Sendable {
    public let kind: ModelKind
    public let index: Int
    public let reason: String
}

public enum CatalogError: Error, Equatable, Sendable {
    case notJSONObject
    case badSchema
    case missingKind(String)
    case unknownKey(String)
}

public struct ModelCatalog: Equatable, Sendable {
    public let schema: Int
    public let whisper: [ModelEntry]
    public let vad: [ModelEntry]
    public let llm: [ModelEntry]
    /// 読み込みで捨てた項目（OPS-19。診断とログに出す）。
    public let rejected: [CatalogRejection]

    /// トップのキー。
    static let topKeys: Set<String> = ["schema", "whisper", "vad", "llm"]
    /// 全 kind に共通の項目のキー。
    static let commonKeys: Set<String> = ["id", "displayName", "file", "url", "sha256", "bytes", "license"]
    /// llm だけが持つ項目のキー。
    static let llmOnlyKeys: Set<String> = ["minMemoryGB", "verified"]
    /// 文字列でなければならない 6 つ。
    static let stringKeys: [String] = ["id", "displayName", "file", "url", "sha256", "license"]
    static let urlPrefix = "https://huggingface.co/"
    static let resolveSegment = "/resolve/"

    public static func load(_ data: Data) -> Result<ModelCatalog, CatalogError> {
        guard let parsed = try? JSONSerialization.jsonObject(with: data), let top = parsed as? [String: Any] else {
            return .failure(.notJSONObject)
        }
        if let unknown = top.keys.sorted().first(where: { !topKeys.contains($0) }) {
            return .failure(.unknownKey(unknown))
        }
        guard let schema = integer(top["schema"]), schema == 1 else {
            return .failure(.badSchema)
        }
        var lists: [ModelKind: [Any]] = [:]
        for kind in ModelKind.allCases {
            guard let items = top[kind.rawValue] as? [Any] else {
                return .failure(.missingKind(kind.rawValue))
            }
            lists[kind] = items
        }
        var accepted: [ModelKind: [ModelEntry]] = [:]
        var rejected: [CatalogRejection] = []
        for kind in ModelKind.allCases {
            var entries: [ModelEntry] = []
            for (index, item) in (lists[kind] ?? []).enumerated() {
                switch parseEntry(item, kind: kind) {
                case .failure(let reason):
                    rejected.append(CatalogRejection(kind: kind, index: index, reason: reason.rawValue))
                case .success(let entry):
                    if entries.contains(where: { $0.id == entry.id }) {
                        rejected.append(CatalogRejection(kind: kind, index: index, reason: "duplicate_id"))
                    } else {
                        entries.append(entry)
                    }
                }
            }
            accepted[kind] = entries
        }
        return .success(
            ModelCatalog(
                schema: schema, whisper: accepted[.whisper] ?? [], vad: accepted[.vad] ?? [],
                llm: accepted[.llm] ?? [], rejected: rejected))
    }

    public func entries(kind: ModelKind) -> [ModelEntry] {
        switch kind {
        case .whisper: return whisper
        case .vad: return vad
        case .llm: return llm
        }
    }

    public func entry(kind: ModelKind, id: String) -> ModelEntry? {
        entries(kind: kind).first { $0.id == id }
    }

    /// パネルの一覧に出す LLM（`verified == true` だけ。PLAN §8.10）。
    public var listedLLMs: [ModelEntry] { llm.filter { $0.verified == true } }

    /// 不合格の理由（判定の順）。
    enum Rejection: String, Error {
        case notObject = "not_object"
        case unknownKey = "unknown_key"
        case missingKey = "missing_key"
        case wrongType = "wrong_type"
        case badID = "bad_id"
        case badFileName = "bad_file_name"
        case badURL = "bad_url"
        case badSHA256 = "bad_sha256"
        case badBytes = "bad_bytes"
        case badMinMemory = "bad_min_memory"
    }

    /// 1 項目の検査。`duplicate_id` は呼び手が見る。
    static func parseEntry(_ item: Any, kind: ModelKind) -> Result<ModelEntry, Rejection> {
        guard let object = item as? [String: Any] else { return .failure(.notObject) }
        let allowed = kind == .llm ? commonKeys.union(llmOnlyKeys) : commonKeys
        if object.keys.contains(where: { !allowed.contains($0) }) { return .failure(.unknownKey) }
        if allowed.contains(where: { object[$0] == nil }) { return .failure(.missingKey) }
        var strings: [String: String] = [:]
        for key in stringKeys {
            guard let value = object[key] as? String else { return .failure(.wrongType) }
            strings[key] = value
        }
        guard let bytes = integer(object["bytes"]) else { return .failure(.wrongType) }
        var minMemoryGB: Int?
        var verified: Bool?
        if kind == .llm {
            guard let memory = integer(object["minMemoryGB"]) else { return .failure(.wrongType) }
            guard let flag = boolean(object["verified"]) else { return .failure(.wrongType) }
            minMemoryGB = memory
            verified = flag
        }
        let id = strings["id"] ?? ""
        let file = strings["file"] ?? ""
        let url = strings["url"] ?? ""
        let sha256 = strings["sha256"] ?? ""
        guard isValidID(id) else { return .failure(.badID) }
        guard isValidFileName(file) else { return .failure(.badFileName) }
        guard isValidURL(url, file: file) else { return .failure(.badURL) }
        guard isLowerHex(sha256, count: 64) else { return .failure(.badSHA256) }
        guard bytes > 0 else { return .failure(.badBytes) }
        if let memory = minMemoryGB, memory < 1 { return .failure(.badMinMemory) }
        return .success(
            ModelEntry(
                id: id, displayName: strings["displayName"] ?? "", file: file, url: url, sha256: sha256,
                bytes: Int64(bytes), license: strings["license"] ?? "", minMemoryGB: minMemoryGB, verified: verified))
    }

    /// 整数（bool でも浮動小数でもない `NSNumber`）なら値。
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            !CFNumberIsFloatType(number)
        else { return nil }
        return number.intValue
    }

    /// bool の `NSNumber` なら値。
    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// 空でなく、`[a-z0-9]` で始まり `[a-z0-9._-]` だけ。
    static func isValidID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, isLowerAlnum(first) else { return false }
        return id.unicodeScalars.allSatisfy { isLowerAlnum($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    /// `[A-Za-z0-9._-]` だけ、空でない、`.` で始まらない、`..` を含まない（OPS-19）。
    static func isValidFileName(_ file: String) -> Bool {
        guard !file.isEmpty, !file.hasPrefix("."), !file.contains("..") else { return false }
        return file.unicodeScalars.allSatisfy { scalar in
            isLowerAlnum(scalar) || ("A"..."Z").contains(scalar) || scalar == "." || scalar == "_" || scalar == "-"
        }
    }

    /// `https://huggingface.co/` で始まり、`/resolve/` の直後が 40 桁の小文字 16 進 + `/`、`"/" + file` で終わる。
    static func isValidURL(_ url: String, file: String) -> Bool {
        guard url.hasPrefix(urlPrefix), let resolve = url.range(of: resolveSegment) else { return false }
        let after = url[resolve.upperBound...]
        let commit = String(after.prefix(40))
        guard isLowerHex(commit, count: 40), after.dropFirst(40).hasPrefix("/") else { return false }
        return url.hasSuffix("/" + file)
    }

    /// ちょうど `count` 文字の小文字 16 進。
    static func isLowerHex(_ text: String, count: Int) -> Bool {
        text.unicodeScalars.count == count
            && text.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    private static func isLowerAlnum(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
    }
}

public enum CustomModelID {
    public static let prefix = "custom:"

    public static func make(sha256: String) -> String { prefix + sha256 }

    /// `custom:<64 桁の小文字 16 進>` なら 16 進の部分、そうでなければ nil。
    public static func sha256(of id: String) -> String? {
        guard id.hasPrefix(prefix) else { return nil }
        let rest = String(id.dropFirst(prefix.count))
        return ModelCatalog.isLowerHex(rest, count: 64) ? rest : nil
    }

    /// `custom-<sha256 の先頭 16>.gguf`
    public static func fileName(sha256: String) -> String {
        "custom-" + String(sha256.prefix(16)) + ".gguf"
    }
}
