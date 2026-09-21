// PT-13: 版・URL・action・ランナーの固定（PLAN §3.3・§9.4。T-04）。
import Foundation

enum PinningPolicy {
    static let id = "PT-13"

    /// `root`（リポジトリのルート）の下を検査する。`requiredFiles` のファイルが無ければ違反。
    static func check(root: URL, requiredFiles: [String]) -> [Violation] {
        var violations: [Violation] = []
        for path in requiredFiles
        where !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path(percentEncoded: false)) {
            violations.append(Violation(rule: id, path: path, line: 1, what: "ファイルがありません"))
        }
        violations += checkPackageSwift(root: root)
        violations += checkPackageResolved(root: root)
        violations += checkVersionsEnv(root: root)
        violations += checkModelCatalog(root: root)
        violations += checkWorkflows(root: root)
        violations += checkXcodeVersion(root: root)
        return violations
    }

    static func read(_ root: URL, _ path: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.firstMatch(in: text, range: range)?.range == range
    }

    /// Package.swift の `.package(` ごとに `exact:` があり、`from:` などの範囲指定が無い。
    static func checkPackageSwift(root: URL) -> [Violation] {
        guard let text = read(root, "Package.swift") else { return [] }
        let tokens = CodeTokenizer.tokens(SourceScanner.scan(text).code)
        let forbidden: Set<String> = ["from", "branch", "revision", "upToNextMajor", "upToNextMinor", "path"]
        var violations: [Violation] = []
        var index = 0
        while index + 2 < tokens.count {
            guard tokens[index].text == ".", tokens[index + 1].text == "package", tokens[index + 2].text == "(" else {
                index += 1
                continue
            }
            var depth = 0
            var end = index + 2
            var body: [CodeToken] = []
            while end < tokens.count {
                if tokens[end].text == "(" { depth += 1 }
                if tokens[end].text == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                body.append(tokens[end])
                end += 1
            }
            let words = Set(body.filter { $0.kind == .identifier }.map(\.text))
            let texts = body.map(\.text).joined()
            if !words.contains("exact") || !words.isDisjoint(with: forbidden) || texts.contains("..<")
                || texts.contains("...")
            {
                violations.append(
                    Violation(rule: id, path: "Package.swift", line: tokens[index].line, what: ".package( が exact: でない")
                )
            }
            index = end + 1
        }
        return violations
    }

    /// Package.resolved の各 pin が version（x.y.z）と 40 桁の revision を持ち、branch を持たない。
    static func checkPackageResolved(root: URL) -> [Violation] {
        guard let text = read(root, "Package.resolved"), let data = text.data(using: .utf8) else { return [] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let pins = object["pins"] as? [[String: Any]]
        else {
            return [Violation(rule: id, path: "Package.resolved", line: 1, what: "JSON を読めません")]
        }
        var violations: [Violation] = []
        for pin in pins {
            let identity = pin["identity"] as? String ?? "?"
            let state = pin["state"] as? [String: Any] ?? [:]
            let version = state["version"] as? String ?? ""
            let revision = state["revision"] as? String ?? ""
            if !matches("[0-9]+\\.[0-9]+\\.[0-9]+", version) || !matches("[0-9a-f]{40}", revision)
                || state["branch"] != nil
            {
                violations.append(
                    Violation(rule: id, path: "Package.resolved", line: 1, what: "\(identity) が版で固定されていない"))
            }
        }
        return violations
    }

    /// versions.env の REF がタグ、SHA が 40 桁、REPO が ggml-org の GitHub。
    static func checkVersionsEnv(root: URL) -> [Violation] {
        guard let text = read(root, "Vendor/versions.env") else { return [] }
        let rules: [String: String] = [
            "WHISPER_CPP_REPO": "https://github\\.com/ggml-org/whisper\\.cpp\\.git",
            "WHISPER_CPP_REF": "v[0-9]+\\.[0-9]+\\.[0-9]+",
            "WHISPER_CPP_SHA": "[0-9a-f]{40}",
            "LLAMA_CPP_REPO": "https://github\\.com/ggml-org/llama\\.cpp\\.git",
            "LLAMA_CPP_REF": "b[0-9]+",
            "LLAMA_CPP_SHA": "[0-9a-f]{40}",
        ]
        var values: [String: String] = [:]
        var violations: [Violation] = []
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let equals = trimmed.firstIndex(of: "=") else {
                violations.append(
                    Violation(rule: id, path: "Vendor/versions.env", line: offset + 1, what: "KEY=VALUE でない"))
                continue
            }
            values[String(trimmed[..<equals])] = String(trimmed[trimmed.index(after: equals)...])
        }
        for (key, pattern) in rules.sorted(by: { $0.key < $1.key }) where !matches(pattern, values[key] ?? "") {
            violations.append(Violation(rule: id, path: "Vendor/versions.env", line: 1, what: "\(key) の形が違う"))
        }
        return violations
    }

    /// ModelCatalog.json（在れば）の各 url が huggingface.co のコミット SHA 固定。
    static func checkModelCatalog(root: URL) -> [Violation] {
        guard let text = read(root, "Resources/ModelCatalog.json"), let data = text.data(using: .utf8) else {
            return []
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [Violation(rule: id, path: "Resources/ModelCatalog.json", line: 1, what: "JSON を読めません")]
        }
        var violations: [Violation] = []
        for kind in ["whisper", "vad", "llm"] {
            for entry in object[kind] as? [[String: Any]] ?? [] {
                let url = entry["url"] as? String ?? ""
                if !matches("https://huggingface\\.co/[^/]+/[^/]+/resolve/[0-9a-f]{40}/[^/]+", url) {
                    violations.append(
                        Violation(rule: id, path: "Resources/ModelCatalog.json", line: 1, what: "url が固定されていない: \(url)")
                    )
                }
            }
        }
        return violations
    }

    /// .github/workflows/*.yml の uses: が 40 桁の SHA、runs-on: に latest が無い。
    static func checkWorkflows(root: URL) -> [Violation] {
        let directory = root.appendingPathComponent(".github/workflows")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        var violations: [Violation] = []
        for name in names.sorted() where name.hasSuffix(".yml") || name.hasSuffix(".yaml") {
            let path = ".github/workflows/\(name)"
            guard let text = read(root, path) else { continue }
            for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(rawLine.prefix { $0 != "#" }).trimmingCharacters(in: .whitespaces)
                let body = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
                if body.hasPrefix("uses:") {
                    let value = body.dropFirst("uses:".count).trimmingCharacters(in: .whitespaces)
                    if !matches("[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}", value) {
                        violations.append(
                            Violation(rule: id, path: path, line: offset + 1, what: "uses: が SHA で固定されていない"))
                    }
                }
                if body.hasPrefix("runs-on:") && body.lowercased().contains("latest") {
                    violations.append(Violation(rule: id, path: path, line: offset + 1, what: "runs-on: に latest"))
                }
            }
        }
        return violations
    }

    /// .xcode-version がちょうど 1 行。
    static func checkXcodeVersion(root: URL) -> [Violation] {
        guard let text = read(root, ".xcode-version") else { return [] }
        return matches("[0-9]+\\.[0-9]+(\\.[0-9]+)?\\n", text)
            ? [] : [Violation(rule: id, path: ".xcode-version", line: 1, what: "1 行でない")]
    }
}
