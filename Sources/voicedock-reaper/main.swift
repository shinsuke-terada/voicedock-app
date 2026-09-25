// voicedock-reaper の入口（PLAN §8.9.4）。`print` と stderr への書き出しはこのファイルだけ（PT-08）。
import Foundation

let result = ReaperMain.run(arguments: Array(CommandLine.arguments.dropFirst()))
if !result.stdout.isEmpty { print(result.stdout, terminator: "") }
if !result.stderr.isEmpty { FileHandle.standardError.write(Data(result.stderr.utf8)) }
exit(result.code)
