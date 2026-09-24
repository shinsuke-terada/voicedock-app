// argmax-cli の RTTM（PLAN §8.4.1）。
import Foundation
import VDCore

public struct SpeakerTurn: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let speaker: String

    public init(start: Double, end: Double, speaker: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

public enum RTTMParser {
    /// 1 行の列の数の下限。
    static let minColumns = 8
    /// 1 列目（行の種類）。
    static let speakerType = "SPEAKER"
    /// 開始と長さの列に在ってよいスカラー（PLAN §8.4.1 の「10 進の数」。Double(String) は 16 進も受けるので先に見る）。
    static let decimalScalars: Set<Unicode.Scalar> = [
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "+", "-", "e", "E",
    ]

    /// 1 行でも不正なら nil。0 行は []。
    public static func parse(_ text: String) -> [SpeakerTurn]? {
        var turns: [SpeakerTurn] = []
        // "\r\n" は Swift の Character では 1 つなので、スカラーの "\n" で分ける
        for rawLine in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            var scalars = String.UnicodeScalarView(rawLine)
            if scalars.last == "\r" { scalars.removeLast() }
            let line = PyText.strip(String(scalars))
            if line.isEmpty { continue }
            let columns = line.unicodeScalars.split(whereSeparator: { $0 == " " || $0 == "\t" }).map {
                String(String.UnicodeScalarView($0))
            }
            guard columns.count >= minColumns, columns[0] == speakerType else { return nil }
            guard isDecimal(columns[3]), isDecimal(columns[4]), let start = Double(columns[3]),
                let duration = Double(columns[4]), start.isFinite,
                duration.isFinite, start >= 0, duration >= 0
            else { return nil }
            let speaker = columns[7]
            guard !speaker.isEmpty else { return nil }
            turns.append(SpeakerTurn(start: start, end: start + duration, speaker: speaker))
        }
        return turns
    }

    /// 10 進の数に使うスカラーだけでできている。
    static func isDecimal(_ column: String) -> Bool {
        column.unicodeScalars.allSatisfy { decimalScalars.contains($0) }
    }
}
