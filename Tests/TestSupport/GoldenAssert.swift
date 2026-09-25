// golden の期待値と実際の出力を比べ、違えば unified diff を付けて記録する（PLAN §10.4、T-25）。
import Foundation
import Testing

/// golden の比較。違いは `Issue.record` で記録する（テストを止めない。1 本のテストで全ケースを見るため）。
public enum GoldenAssert {
    /// `.md` / `.out` の期待値と、文字列の UTF-8 のバイト列で比べる。
    public static func matches(
        _ actual: String, group: String, name: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        matches(bytes: Data(actual.utf8), group: group, name: name, sourceLocation: sourceLocation)
    }

    /// `.md` / `.out` の期待値とバイト列で比べる。
    public static func matches(
        bytes actual: Data, group: String, name: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let url: URL
        let expected: Data
        do {
            url = try Golden.expectedFile(group, name)
            expected = try Golden.expectedBytes(group, name)
        } catch {
            Issue.record(Comment(rawValue: "\(error)"), sourceLocation: sourceLocation)
            return
        }
        guard Golden.byteExtensions.contains(url.pathExtension) else {
            Issue.record(
                Comment(rawValue: "golden \(group)/\(name) は値で比べる期待値です（matchesJSON を使う）"),
                sourceLocation: sourceLocation)
            return
        }
        if actual == expected {
            return
        }
        let label = "Tests/Golden/expected/\(group)/\(name).\(url.pathExtension)"
        var message = "golden 不一致: \(label)（期待 \(expected.count) バイト、実際 \(actual.count) バイト）\n"
        let diff = UnifiedDiff.render(
            expected: String(decoding: expected, as: UTF8.self), actual: String(decoding: actual, as: UTF8.self),
            expectedLabel: label, actualLabel: "actual")
        message += diff.isEmpty ? "（UTF-8 の文字列としては同じ。BOM・不正な UTF-8 などバイト列の違い）\n" : diff
        message += writeActual(actual, group: group, name: name, ext: url.pathExtension)
        Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
    }

    /// `.json` の期待値と値で比べる（文字列は Unicode スカラー列、オブジェクトはキーの順を問わない）。
    public static func matchesJSON(
        _ actual: GoldenJSON, group: String, name: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let expected: GoldenJSON
        do {
            expected = try Golden.expectedJSON(group, name)
        } catch {
            Issue.record(Comment(rawValue: "\(error)"), sourceLocation: sourceLocation)
            return
        }
        if actual == expected {
            return
        }
        let label = "Tests/Golden/expected/\(group)/\(name).json"
        var message = "golden 不一致: \(label)\n"
        message += UnifiedDiff.render(
            expected: expected.description, actual: actual.description, expectedLabel: label + "（キーを並べ替えて表示）",
            actualLabel: "actual")
        message += writeActual(Data((actual.description + "\n").utf8), group: group, name: name, ext: "json")
        Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
    }

    /// `VOICEDOCK_GOLDEN_WRITE_ACTUAL=1` のとき、実際の出力を `.build/golden-actual/<group>/<name>.<ext>` に書く。
    static func writeActual(_ data: Data, group: String, name: String, ext: String) -> String {
        guard TestEnvironment.goldenWriteActual else {
            return ""
        }
        let directory = PackageRoot.file(".build/golden-actual/\(group)")
        let file = directory.appendingPathComponent("\(name).\(ext)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file)
            return "実際の出力: \(file.path)\n"
        } catch {
            return "実際の出力を書けませんでした: \(file.path)\n"
        }
    }
}
