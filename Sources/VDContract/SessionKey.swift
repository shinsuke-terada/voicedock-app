// session_key の組み立てと分解（PLAN §4.2）。
import Foundation

public enum SessionKey {
    /// 1. DeviceID.isValid が偽 → .invalidDeviceID
    /// 2. dayStamp が ASCII 数字ちょうど 8 桁で、LocalDateTime(year:month:day:hour:0,minute:0,second:0) が作れること。でなければ .invalidDayStamp
    /// 3. overflow < 1 → .invalidOverflow
    /// 4. overflow == 1 → "\(deviceID):\(dayStamp)"、それ以外 → "\(deviceID):\(dayStamp)#\(overflow)"（"#1" は作らない）
    public static func make(deviceID: String, dayStamp: String, overflow: Int = 1) throws(KeyError) -> String {
        guard DeviceID.isValid(deviceID) else { throw .invalidDeviceID }
        guard isEightASCIIDigits(dayStamp) else { throw .invalidDayStamp }
        let digits = Array(dayStamp)
        guard let year = Int(String(digits[0..<4])), let month = Int(String(digits[4..<6])),
            let day = Int(String(digits[6..<8])),
            LocalDateTime(year: year, month: month, day: day, hour: 0, minute: 0, second: 0) != nil
        else { throw .invalidDayStamp }
        guard overflow >= 1 else { throw .invalidOverflow }
        if overflow == 1 {
            return "\(deviceID):\(dayStamp)"
        }
        return "\(deviceID):\(dayStamp)#\(overflow)"
    }

    /// 最後の ":" より前。":" が無い・前が空なら nil
    public static func deviceID(of key: String) -> String? {
        guard let colon = key.lastIndex(of: ":") else { return nil }
        let head = key[..<colon]
        return head.isEmpty ? nil : String(head)
    }

    /// 最後の ":" より後から "#…" を除いた部分が ASCII 数字 8 桁ならそれ。でなければ nil
    public static func dayStamp(of key: String) -> String? {
        guard let colon = key.lastIndex(of: ":") else { return nil }
        let tail = key[key.index(after: colon)...]
        let day = String(tail.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        return isEightASCIIDigits(day) ? day : nil
    }

    /// "#" が無ければ 1。"#" の後が正規表現 ^[1-9][0-9]*$ に一致し、Int にでき、2 以上ならその値。それ以外は nil（"#1"・"#02"・"#x" は nil）
    public static func overflow(of key: String) -> Int? {
        let tail: Substring
        if let colon = key.lastIndex(of: ":") {
            tail = key[key.index(after: colon)...]
        } else {
            tail = key[...]
        }
        guard let hash = tail.firstIndex(of: "#") else { return 1 }
        let suffix = String(tail[tail.index(after: hash)...])
        guard PatternMatch.wholeMatch("^[1-9][0-9]*$", suffix) != nil, let n = Int(suffix), n >= 2 else {
            return nil
        }
        return n
    }

    /// deviceID(of:)・dayStamp(of:)・overflow(of:) のどれかが nil → throw .malformedKey。
    /// そうでなければ make(deviceID:dayStamp:overflow: overflow + 1)（接尾辞無し → "#2"、"#n" → "#(n+1)"）
    public static func nextOverflow(_ key: String) throws(KeyError) -> String {
        guard let device = deviceID(of: key), let day = dayStamp(of: key), let current = overflow(of: key) else {
            throw .malformedKey
        }
        return try make(deviceID: device, dayStamp: day, overflow: current + 1)
    }

    /// Unicode スカラーがすべて U+0030〜U+0039 で、ちょうど 8 個（`Character.isNumber` は全角数字も真にするので使わない）。
    private static func isEightASCIIDigits(_ s: String) -> Bool {
        s.unicodeScalars.count == 8 && s.unicodeScalars.allSatisfy { $0.value >= 0x30 && $0.value <= 0x39 }
    }
}
