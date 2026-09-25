// 引数の解析（PLAN §8.9.4）。`--home <HOME>` か `--version` だけ。
enum ReaperArguments: Equatable, Sendable {
    case version
    case run(home: String)
    case invalid

    static let usage = "usage: voicedock-reaper --home <HOME> | --version\n"

    /// CommandLine.arguments の先頭（実行ファイル名）を落としたもの。完全一致。ほかの形は全部 `.invalid`
    static func parse(_ arguments: [String]) -> ReaperArguments {
        if arguments == ["--version"] { return .version }
        if arguments.count == 2 && arguments[0] == "--home" && !arguments[1].isEmpty {
            return .run(home: arguments[1])
        }
        return .invalid
    }
}
