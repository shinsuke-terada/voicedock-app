// ChunkReading の差し替え（読み取りエラー・短い読み取り。T-14）。
import Foundation
import VDDevice

/// ChunkReading の差し替え。bytes を chunk ごとに返し、failAfterChunks 回読んだ後は ErrnoError(failErrno) を投げる
public final class FakeChunkReader: ChunkReading {
    private let bytes: Data
    private let failAfterChunks: Int?
    private let failErrno: Int32
    private var offset = 0
    private var chunksRead = 0

    public init(bytes: Data, failAfterChunks: Int? = nil, failErrno: Int32 = EIO) {
        self.bytes = bytes
        self.failAfterChunks = failAfterChunks
        self.failErrno = failErrno
    }

    /// read に渡された maxBytes（呼ばれた順）
    public private(set) var requestedSizes: [Int] = []

    public func read(maxBytes: Int) throws(ErrnoError) -> Data {
        requestedSizes.append(maxBytes)
        if let limit = failAfterChunks, chunksRead >= limit { throw ErrnoError(failErrno) }
        chunksRead += 1
        let end = min(offset + maxBytes, bytes.count)
        let chunk = bytes.subdata(in: offset..<end)
        offset = end
        return chunk
    }
}
