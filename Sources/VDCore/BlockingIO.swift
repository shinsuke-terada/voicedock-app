// actor の中で長い同期 I/O をしないための逃がし先（PLAN §2.1）。
import Foundation

/// actor の中で長い同期 I/O をしないための逃がし先（PLAN §2.1）。
public enum BlockingIO {
    static let queue = DispatchQueue(label: "voicedock.blocking-io", qos: .utility, attributes: .concurrent)
    /// work を専用の並行キューで実行し、結果を continuation で返す。
    /// work の中のキャンセルは呼び手が時間の上限で行う（Task のキャンセルは work に伝わらない）。
    public static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
