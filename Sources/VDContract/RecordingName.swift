// DJI Mic 3 の録音ファイル名とフォルダ名の規則（PLAN §4.1）。
import Foundation

public enum RecordingName {
    /// ファイル名。逐語（Swift のソースでは raw 文字列 #"…"# で書く）。
    public static let filePattern = #"^(TX[0-9]{2})_(MIC[0-9]{3})_([0-9]{8})_([0-9]{6})(_orig)?\.(wav|WAV)$"#
    /// フォルダ名。逐語。
    public static let folderPattern = #"^TX_(MIC[0-9]{3})_([0-9]{8})_([0-9]{6})$"#

    /// 規則に一致し、日時が実在するときだけ値を返す（2/30・13 月・24 時などは例外にせず nil）。
    public static func parseFile(_ name: String) -> ParsedFile? {
        guard let groups = PatternMatch.wholeMatch(filePattern, name), groups.count == 7,
            let transmitterID = groups[1], let mic = groups[2], let date = groups[3], let time = groups[4],
            let ext = groups[6],
            let micIndex = Int(mic.dropFirst(3))
        else { return nil }
        let d = Array(date)
        let t = Array(time)
        guard let year = Int(String(d[0..<4])), let month = Int(String(d[4..<6])), let day = Int(String(d[6..<8])),
            let hour = Int(String(t[0..<2])), let minute = Int(String(t[2..<4])), let second = Int(String(t[4..<6])),
            let local = LocalDateTime(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        else { return nil }
        return ParsedFile(
            transmitterID: transmitterID, micIndex: micIndex, local: local, isOrig: groups[5] != nil, ext: ext)
    }

    /// ファイル名の規則の形だけを見る（日時の妥当性は見ない。走査で「形は一致するが日時が不正」＝ `unparsable_filename` を見分けるため。T-14）
    public static func matchesFilePattern(_ name: String) -> Bool {
        PatternMatch.wholeMatch(filePattern, name) != nil
    }

    /// フォルダ名の規則（日時の妥当性は見ない。voicedock の `RECORDING_FOLDER_RE` と同じ）。
    public static func isFolder(_ name: String) -> Bool {
        PatternMatch.wholeMatch(folderPattern, name) != nil
    }
}

public struct ParsedFile: Equatable, Sendable {
    /// "TX01"（文字列のまま）
    public let transmitterID: String
    /// "MIC002" → 2
    public let micIndex: Int
    /// ファイル名の年月日時分秒（オフセット無し。TIME-03: タイムゾーンは付与するだけで変換しない）
    public let local: LocalDateTime
    /// `_orig` が付いているか（取り込みも削除も `_orig` だけ。DEL-34）
    public let isOrig: Bool
    /// "wav" か "WAV"
    public let ext: String
}
