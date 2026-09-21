// golden の入力のオブジェクトの配列をキーの順のまま読む（T-45 の GoldenCase.orderedObject と同じ読み方。T-20 §5.0）。
import Foundation
import TestSupport
import VDCore

extension GoldenCase {
    /// このケースの `key` の値（各要素がオブジェクトの配列）を、キーの順を保って返す。
    /// 入力 `Tests/Golden/inputs/<group>.json` を `PyJSON.decode` で読み直す。形が違えば `typeMismatch(expected: "array of object")`。
    func orderedList(_ key: String) throws -> [[(String, PyJSONValue)]] {
        let url = Golden.inputsDirectory.appendingPathComponent("\(group).json")
        guard let data = try? Data(contentsOf: url) else {
            throw GoldenError.unreadable(url.path(percentEncoded: false))
        }
        guard let document = PyJSON.decode(data), case .object(let top) = document,
            let casesValue = Self.listMember(top, "cases"), case .array(let items) = casesValue
        else {
            throw GoldenError.malformedInput(url.path(percentEncoded: false))
        }
        for item in items {
            guard case .object(let itemFields) = item,
                let nameValue = Self.listMember(itemFields, "name"), case .string(let itemName) = nameValue
            else {
                throw GoldenError.malformedInput(url.path(percentEncoded: false))
            }
            guard PyText.scalarsEqual(itemName, name) else { continue }
            guard let found = Self.listMember(itemFields, key) else {
                throw GoldenError.missingKey(group: group, name: name, key: key)
            }
            let mismatch = GoldenError.typeMismatch(group: group, name: name, key: key, expected: "array of object")
            guard case .array(let elements) = found else {
                throw mismatch
            }
            return try elements.map { element in
                guard case .object(let pairs) = element else {
                    throw mismatch
                }
                return pairs
            }
        }
        throw GoldenError.noSuchCase(group: group, name: name)
    }

    /// キーの突き合わせはスカラー列。最初に一致したものを返す。
    private static func listMember(_ pairs: [(String, PyJSONValue)], _ key: String) -> PyJSONValue? {
        pairs.first { PyText.scalarsEqual($0.0, key) }?.1
    }
}
