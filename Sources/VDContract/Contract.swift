// アプリと reaper が共有する定数（PLAN §4.5）。
import Foundation

public enum Contract {
    /// RV-12。アプリの事前確認も同じ値を使う。
    public static let mtimeToleranceSeconds: Double = 2.0
    public static let requestSchema = 1
    public static let resultSchema = 1
    public static let reaperConfSchema = 1
    public static let reaperFileName = "voicedock-reaper"
    /// reaper.conf の VOLUMES_ROOT で上書きできる（テスト用）。
    public static let volumesRoot = "/Volumes"
    /// RV-06。DJI Mic 3 は MS-DOS FAT32（実機の mount 出力: msdos, local, nodev, nosuid, noowners, noatime, fskit）。
    public static let expectedFilesystem = "msdos"
    /// 要求ファイルと reaper.conf の上限（バイト）。
    public static let maxRequestBytes = 65_536
}
