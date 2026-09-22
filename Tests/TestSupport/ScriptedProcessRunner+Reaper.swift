// reaper の --version の結果（T-13 の ScriptedProcessRunner への extension。作り手 T-36）。
import Foundation
import VDContract
import VDProcess

extension ScriptedProcessRunner {
    /// 終了コード 0、stdout = output（既定は AppVersion.string + "\n"）、stderr は空
    public static func version(_ output: String = AppVersion.string + "\n") -> ProcessResult {
        ProcessResult(termination: .exited(0), stdoutTail: Data(output.utf8), stderrTail: Data())
    }
}
