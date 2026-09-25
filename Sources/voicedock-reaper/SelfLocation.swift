// RV-00: 自分が `<HOME>/bin/voicedock-reaper` から起動されたことを確かめる（PLAN §8.9.3 の 3）。
import Darwin
import Foundation
import VDContract

enum SelfLocation {
    /// `.app/Contents/` を含むパスは常に偽（バンドル内の reaper を直接起動された場合）
    static let bundleMarker = ".app/Contents/"

    /// `_NSGetExecutablePath` → `realpath(3)`。失敗で nil
    static func executablePath() -> String? {
        var size = UInt32(PATH_MAX)
        var buf = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buf, &size) != 0 {
            // バッファが足りない（size に要る大きさが入る）。作り直して 1 回だけやり直す
            buf = [CChar](repeating: 0, count: Int(size))
            guard _NSGetExecutablePath(&buf, &size) == 0 else { return nil }
        }
        // String(cString:) の配列版は非推奨（警告はエラー）。NUL の手前までを UTF-8 として読む
        let raw = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        // symlink 経由で起動された場合に実体へ直す
        return ReaperIO.realpath(raw)
    }

    /// RV-00。真でなければ呼び手は何も書かずに終了コード 3。この関数はログを書かない
    static func isAtExpectedPlace(home: String) -> Bool {
        guard let selfPath = executablePath() else { return false }
        // `<HOME>` を `.app/Contents/` の下に作られても弾く（下の一致の検査より先に置く）
        if selfPath.contains(Self.bundleMarker) { return false }
        guard let homeReal = ReaperIO.realpath(home) else { return false }
        let layout = HomeLayout(root: URL(fileURLWithPath: homeReal, isDirectory: true))
        let expected = layout.reaperExecutable.path(percentEncoded: false)
        // バイト列の完全一致（Swift の == は正準等価で比べるため使わない）
        guard Array(selfPath.utf8) == Array(expected.utf8) else { return false }
        // lstat。symlink・ディレクトリを拒む
        guard ReaperIO.isRegularFile(expected) else { return false }
        return true
    }
}
