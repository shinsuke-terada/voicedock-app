// 署名検証の偽物（PLAN §10.2。作り手 T-36）。呼ばれた URL を記録し、setValid の値を返す。
import Foundation
import Synchronization
import VDPipeline

public final class FakeSignatureVerifier: SignatureVerifier {
    private let state: Mutex<(valid: Bool, urls: [URL])>

    public init(valid: Bool = true) {
        state = Mutex((valid: valid, urls: []))
    }

    public func setValid(_ valid: Bool) {
        state.withLock { $0.valid = valid }
    }

    /// urls に足し、valid を返す
    public func verify(url: URL) -> Bool {
        state.withLock {
            $0.urls.append(url)
            return $0.valid
        }
    }

    public var verifiedURLs: [URL] { state.withLock { $0.urls } }
}
