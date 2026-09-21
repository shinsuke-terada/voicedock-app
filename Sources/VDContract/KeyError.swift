// 鍵の組み立てと分解の失敗（プログラムの誤り。ErrorCode を持たない）。
import Foundation

public enum KeyError: Error, Equatable, Sendable {
    case invalidDeviceID
    case unsafeRelpath
    case invalidDayStamp
    case invalidOverflow
    case malformedKey
}
