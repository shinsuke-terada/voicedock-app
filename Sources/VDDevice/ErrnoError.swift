// errno をそのまま運ぶエラー（ロケールに依存する説明文を持たない）。
import Foundation

public struct ErrnoError: Error, Equatable, Sendable {
    public let code: Int32
    public init(_ code: Int32) { self.code = code }
}
