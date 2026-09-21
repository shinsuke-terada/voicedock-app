// waitpid の生の status を終了の仕方に写す（Darwin の WIFEXITED などはマクロで使えないので自前で）。
import Foundation

enum WaitStatus {
    /// nil（回収できなかった）は .exited(-1)。停止状態 0x7f は WUNTRACED を渡さないので起きない
    static func termination(_ raw: Int32?) -> ProcessResult.Termination {
        guard let raw else { return .exited(-1) }
        let low = raw & 0x7f
        if low == 0 { return .exited((raw >> 8) & 0xff) }
        return .signaled(low)
    }
}
