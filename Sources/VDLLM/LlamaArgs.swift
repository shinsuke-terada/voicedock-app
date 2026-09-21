// llama-server の引数（PLAN §8.5）。長い形のフラグだけを使い、固定した版の --help と照合する。
import Foundation

/// llama-server の引数。
public enum LlamaArgs {
    public static let usedFlags: [String] = [
        "--model", "--host", "--port", "--api-key-file", "--ctx-size",
        "--n-gpu-layers", "--jinja", "--parallel", "--no-webui", "--offline",
    ]

    /// argv[0] を含まない引数の列。API キーそのものは置かない（ps で見えるため。PLAN §8.5）。
    public static func build(model: URL, port: UInt16, apiKeyFile: URL, contextSize: Int) -> [String] {
        [
            "--model", model.path(percentEncoded: false),
            "--host", LoopbackEndpoint.host,
            "--port", String(port),
            "--api-key-file", apiKeyFile.path(percentEncoded: false),
            "--ctx-size", String(contextSize),
            "--n-gpu-layers", "999",
            "--jinja",
            "--parallel", "1",
            "--no-webui",
            "--offline",
        ]
    }

    /// usedFlags のうち、help の出力に「語として」現れないものを usedFlags の順に返す。
    public static func missingFlags(helpOutput: String) -> [String] {
        let text = Array(helpOutput.unicodeScalars)
        return usedFlags.filter { !containsWord($0, in: text) }
    }

    /// 出現のうち直前と直後の文字がどちらも [A-Za-z0-9-] でないものが 1 つでも在れば true（`--portable` は `--port` と数えない）。
    private static func containsWord(_ flag: String, in text: [Unicode.Scalar]) -> Bool {
        let pattern = Array(flag.unicodeScalars)
        guard !pattern.isEmpty, text.count >= pattern.count else { return false }
        for start in 0...(text.count - pattern.count) {
            let end = start + pattern.count
            guard text[start..<end].elementsEqual(pattern) else { continue }
            let before = start == 0 || !isFlagScalar(text[start - 1])
            let after = end == text.count || !isFlagScalar(text[end])
            if before && after { return true }
        }
        return false
    }

    private static func isFlagScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "-": return true
        default: return false
        }
    }
}
