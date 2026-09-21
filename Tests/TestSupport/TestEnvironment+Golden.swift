// golden の道具のための TestEnvironment の追加（T-25）。型の作り手は T-01。
import Foundation

extension TestEnvironment {
    /// `VOICEDOCK_GOLDEN_WRITE_ACTUAL=1` のとき、golden の不一致で実際の出力を `.build/golden-actual/` に書く（T-25）。
    public static var goldenWriteActual: Bool {
        ProcessInfo.processInfo.environment["VOICEDOCK_GOLDEN_WRITE_ACTUAL"] == "1"
    }
}
