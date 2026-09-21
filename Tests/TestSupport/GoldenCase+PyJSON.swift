// golden の入力をキーの順のまま読む（T-25 の GoldenCase への extension。PyJSONValue は VDCore なのでここに置く。00-api-map §15）。
import Foundation
import VDCore

extension GoldenCase {
    /// キーの順を保ったオブジェクト。`fields` は辞書で順を持たないので、
    /// 入力 `Tests/Golden/inputs/<group>.json` を `PyJSON.decode` で読み直し、このケースの `key` の値を返す。
    /// 重複キーの扱い（位置は最初・値は後勝ち）も `PyJSON.decode` のまま（4.6）。
    public func orderedObject(_ key: String) throws -> [(String, PyJSONValue)] {
        let url = Golden.inputsDirectory.appendingPathComponent("\(group).json")
        guard let data = try? Data(contentsOf: url) else {
            throw GoldenError.unreadable(url.path)
        }
        guard let document = PyJSON.decode(data), case .object(let top) = document,
            let casesValue = Self.member(top, "cases"), case .array(let items) = casesValue
        else {
            throw GoldenError.malformedInput(url.path)
        }
        for item in items {
            guard case .object(let itemFields) = item,
                let nameValue = Self.member(itemFields, "name"), case .string(let itemName) = nameValue
            else {
                throw GoldenError.malformedInput(url.path)
            }
            guard PyText.scalarsEqual(itemName, name) else { continue }
            guard let found = Self.member(itemFields, key) else {
                throw GoldenError.missingKey(group: group, name: name, key: key)
            }
            guard case .object(let pairs) = found else {
                throw mismatch(key, "オブジェクト")
            }
            return pairs
        }
        throw GoldenError.noSuchCase(group: group, name: name)
    }

    /// キーの突き合わせはスカラー列（4.1。Swift の `==` は正準等価）。最初に一致したものを返す。
    private static func member(_ pairs: [(String, PyJSONValue)], _ key: String) -> PyJSONValue? {
        pairs.first { PyText.scalarsEqual($0.0, key) }?.1
    }
}
