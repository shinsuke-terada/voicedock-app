// PT-07: Sources/ の各モジュールの import が PLAN §3.4 の許可リストに収まる（T-04）。

enum ImportPolicy {
    static let id = "PT-07"

    /// PLAN §3.4 の表の写し。
    static let allowed: [String: Set<String>] = [
        "VDContract": ["Foundation", "Darwin", "CryptoKit"],
        "VDCore": ["Foundation", "Darwin", "os", "CryptoKit", "VDContract"],
        "VDStore": ["Foundation", "VDContract", "VDCore", "GRDB"],
        "VDProcess": ["Foundation", "Darwin", "VDCore"],
        "VDDevice": [
            "Foundation", "Darwin", "AppKit", "CryptoKit", "VDContract", "VDCore", "VDProcess", "VDStore", "VDAudio",
        ],
        "VDAudio": ["Foundation", "AVFoundation", "CryptoKit", "VDContract", "VDCore"],
        "VDTranscribe": ["Foundation", "VDContract", "VDCore", "VDProcess"],
        "VDLLM": ["Foundation", "Darwin", "VDContract", "VDCore", "VDProcess"],
        "VDNotes": ["Foundation", "CryptoKit", "VDContract", "VDCore", "Yams"],
        "VDModels": ["Foundation", "CryptoKit", "VDContract", "VDCore"],
        "VDPipeline": [
            "Foundation", "Darwin", "Security", "CryptoKit", "VDContract", "VDCore", "VDStore", "VDProcess", "VDDevice",
            "VDAudio", "VDTranscribe", "VDLLM", "VDNotes",
        ],
        "VoiceDockApp": [
            "Foundation", "AppKit", "SwiftUI", "ServiceManagement", "os", "VDContract", "VDCore", "VDStore",
            "VDProcess", "VDDevice", "VDAudio", "VDTranscribe", "VDLLM", "VDNotes", "VDModels", "VDPipeline",
        ],
        "voicedock-reaper": ["Foundation", "Darwin", "VDContract"],
    ]

    /// すべてのモジュールで import してよいもの（PLAN §3.4。`Mutex` のため）。
    static let allowedEverywhere: Set<String> = ["Synchronization"]

    /// `import` の対象の前に来てよい種類の語（`import struct Foundation.Date` など）。
    static let importKinds: Set<String> = ["typealias", "struct", "class", "enum", "protocol", "let", "var", "func"]

    /// ファイルの import を（モジュール名, 行）で返す。
    static func imports(in file: SourceFile) -> [(module: String, line: Int)] {
        let tokens = file.tokens
        var result: [(module: String, line: Int)] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let isImport = token.kind == .identifier && token.text == "import"
            let previousIsDot = index > 0 && tokens[index - 1].text == "."
            if isImport && !previousIsDot, index + 1 < tokens.count {
                var next = index + 1
                if importKinds.contains(tokens[next].text), next + 1 < tokens.count { next += 1 }
                if tokens[next].kind == .identifier {
                    result.append((tokens[next].text, token.line))
                }
                index = next + 1
                continue
            }
            index += 1
        }
        return result
    }

    static func check(files: [SourceFile]) -> [Violation] {
        var violations: [Violation] = []
        for file in files {
            guard let allowedModules = allowed[file.module] else {
                violations.append(
                    Violation(rule: id, path: file.relativePath, line: 1, what: "表に無いモジュール \(file.module)"))
                continue
            }
            for item in imports(in: file)
            where !allowedModules.contains(item.module) && !allowedEverywhere.contains(item.module) {
                violations.append(
                    Violation(rule: id, path: file.relativePath, line: item.line, what: "import \(item.module)"))
            }
        }
        return violations
    }
}
