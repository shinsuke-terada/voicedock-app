// golden の不一致を読むための unified diff（行単位、前後 3 行）（PLAN §10.4、T-25）。
import Foundation

/// 2 つの文字列の unified diff。
///
/// - 行は U+000A だけで分ける（`\r\n` の `\r` は行の中身に残り、`\r` と表示される）。末尾が `\n` なら最後に空の行が 1 つある
/// - 見えない文字は見える形にする（`\t`・`\r`・`\u{…}`）
/// - 同じ文字列なら空文字列を返す
public enum UnifiedDiff {
    enum Operation: Equatable {
        case same(Int, Int)
        case removed(Int)
        case added(Int)
    }

    public static func render(
        expected: String, actual: String, expectedLabel: String, actualLabel: String, context: Int = 3
    ) -> String {
        let old = lines(expected)
        let new = lines(actual)
        let operations = diff(old, new)
        guard operations.contains(where: { if case .same = $0 { return false } else { return true } }) else {
            return ""
        }
        var out = "--- \(expectedLabel)\n+++ \(actualLabel)\n"
        for hunk in hunks(operations, context: context) {
            out += header(hunk)
            for operation in hunk {
                switch operation {
                case .same(let index, _): out += " " + visible(old[index]) + "\n"
                case .removed(let index): out += "-" + visible(old[index]) + "\n"
                case .added(let index): out += "+" + visible(new[index]) + "\n"
                }
            }
        }
        return out
    }

    /// U+000A で分けた行（空の区切りも残す）。
    static func lines(_ text: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value == 0x0A {
                result.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        result.append(String(current))
        return result
    }

    /// 最長共通部分列による差分（行の比較は Unicode スカラー列）。
    static func diff(_ old: [String], _ new: [String]) -> [Operation] {
        let rows = old.count
        let columns = new.count
        var table = Array(repeating: Array(repeating: 0, count: columns + 1), count: rows + 1)
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for column in stride(from: columns - 1, through: 0, by: -1) {
                if old[row].unicodeScalars.elementsEqual(new[column].unicodeScalars) {
                    table[row][column] = table[row + 1][column + 1] + 1
                } else {
                    table[row][column] = max(table[row + 1][column], table[row][column + 1])
                }
            }
        }
        var operations: [Operation] = []
        var row = 0
        var column = 0
        while row < rows, column < columns {
            if old[row].unicodeScalars.elementsEqual(new[column].unicodeScalars) {
                operations.append(.same(row, column))
                row += 1
                column += 1
            } else if table[row + 1][column] >= table[row][column + 1] {
                operations.append(.removed(row))
                row += 1
            } else {
                operations.append(.added(column))
                column += 1
            }
        }
        while row < rows {
            operations.append(.removed(row))
            row += 1
        }
        while column < columns {
            operations.append(.added(column))
            column += 1
        }
        return operations
    }

    /// 変更のまとまりごとに、前後 `context` 行の同じ行を付けたハンク。近いハンクは 1 つにまとめる。
    static func hunks(_ operations: [Operation], context: Int) -> [[Operation]] {
        let changed = operations.indices.filter {
            if case .same = operations[$0] { return false } else { return true }
        }
        var ranges: [ClosedRange<Int>] = []
        for index in changed {
            let lower = max(0, index - context)
            let upper = min(operations.count - 1, index + context)
            if let last = ranges.last, lower <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, upper)
            } else {
                ranges.append(lower...upper)
            }
        }
        return ranges.map { Array(operations[$0]) }
    }

    /// `@@ -開始,行数 +開始,行数 @@`（開始は 1 始まり）。
    static func header(_ hunk: [Operation]) -> String {
        var oldIndices: [Int] = []
        var newIndices: [Int] = []
        for operation in hunk {
            switch operation {
            case .same(let old, let new):
                oldIndices.append(old)
                newIndices.append(new)
            case .removed(let old):
                oldIndices.append(old)
            case .added(let new):
                newIndices.append(new)
            }
        }
        // 片側が空のハンク（context が 0 の純粋な挿入など）は開始を 0 と書く
        let oldStart = oldIndices.first.map { $0 + 1 } ?? 0
        let newStart = newIndices.first.map { $0 + 1 } ?? 0
        return "@@ -\(oldStart),\(oldIndices.count) +\(newStart),\(newIndices.count) @@\n"
    }

    /// 見えない文字を見える形にする。
    static func visible(_ line: String) -> String {
        var out = ""
        for scalar in line.unicodeScalars {
            switch scalar.value {
            case 0x09: out += "\\t"
            case 0x0D: out += "\\r"
            case 0x00...0x1F, 0x7F...0x9F, 0x00A0, 0x2000...0x200F, 0x2028...0x202F, 0x205F, 0x3000, 0xFEFF:
                out += "\\u{" + String(scalar.value, radix: 16) + "}"
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
