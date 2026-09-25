// テスト用の DB の行の組み立て（T-11 以降の Store を使うテストが共有する。00-api-map §15 の Builders）。
import Foundation
import VDContract
import VDCore
import VDStore

public enum Builders {
    /// 既定値: deviceID "DJIMIC3"、folder "TX_MIC001_20260829_071201"、transmitter "TX01"、mic 2、
    /// startedAt "2026-08-29T07:12:04+09:00"、duration 1800.0、endedAt "2026-08-29T07:42:04+09:00"、
    /// sourceSize 345_600_000、sourceMtime 1_787_000_000.0（inbox のコピーより 4 時間 34 分前の原本の時刻。DEL-12）、
    /// sha256Helper は "a" × 64、inboxPath "inbox/DJIMIC3/<relpath>"
    public static func recording(
        relpath: String = "TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav",
        startedAt: String = "2026-08-29T07:12:04+09:00",
        durationSeconds: Double? = 1800.0
    ) throws -> NewRecording {
        let deviceID = "DJIMIC3"
        let partkey = try PartKey.make(deviceID: deviceID, relpath: relpath)
        var endedAt: String?
        if let durationSeconds {
            let zone = ZonedTime(timeZone: try tokyo())
            guard let start = zone.parseISO(startedAt) else { throw BuildersError.unparsableStartedAt(startedAt) }
            endedAt = zone.iso(start.adding(seconds: Int(durationSeconds)))
        }
        return NewRecording(
            partkey: partkey, deviceID: deviceID, sourceFolder: RelPath.parent(relpath), transmitterID: "TX01",
            micIndex: 2, startedAt: startedAt, durationSeconds: durationSeconds, endedAt: endedAt,
            sourcePath: relpath, sourceSize: 345_600_000, sourceMtime: 1_787_000_000.0,
            sha256Helper: String(repeating: "a", count: 64), inboxPath: "inbox/" + deviceID + "/" + relpath)
    }

    public static func session(key: String = "DJIMIC3:20260829", dayDate: String = "2026-08-29") -> NewSession {
        NewSession(sessionKey: key, dayDate: dayDate, deviceID: "DJIMIC3")
    }

    /// 一時ディレクトリに Store を開く（FixedClock 2026-08-30T07:00:12+09:00、Asia/Tokyo）
    public static func openStore(in dir: URL, clock: any AppClock) throws -> Store {
        try Store(
            url: dir.appendingPathComponent("voicedock.sqlite"), clock: clock, zone: ZonedTime(timeZone: try tokyo()))
    }

    /// Asia/Tokyo（nil を throw に変える。`!` を使わない）
    private static func tokyo() throws -> TimeZone {
        guard let zone = TimeZone(identifier: "Asia/Tokyo") else { throw BuildersError.missingTimeZone }
        return zone
    }
}

/// Builders の前提が崩れたとき（到達しない想定）。
private enum BuildersError: Error {
    case missingTimeZone
    case unparsableStartedAt(String)
}
