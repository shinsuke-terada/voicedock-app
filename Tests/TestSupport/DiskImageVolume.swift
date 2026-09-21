// hdiutil の FAT32（または HFS+）イメージを一時ディレクトリにマウントする（.diskImage のテストだけが使う）。
// /Volumes の下には決してマウントしない（利用者の実機 /Volumes/DJIMIC3 と衝突させない）。
import Foundation

public final class DiskImageVolume: Sendable {
    public enum Filesystem: Sendable { case fat32, hfsPlus }

    /// <tmp>/Volumes
    public let volumesRoot: URL
    /// <tmp>/Volumes/<deviceID>
    public let mountPoint: URL
    public let deviceID: String
    /// <tmp>/<deviceID>.dmg
    public let image: URL
    public let filesystem: Filesystem

    static let hdiutil = "/usr/bin/hdiutil"

    /// create → mountPoint を作る → attach（書き込み可）
    public init(
        in tmp: TempDirectory, deviceID: String = "VDT0007", filesystem: Filesystem = .fat32, sizeMB: Int = 64
    ) throws {
        volumesRoot = tmp.url.appendingPathComponent("Volumes", isDirectory: true)
        mountPoint = volumesRoot.appendingPathComponent(deviceID, isDirectory: true)
        self.deviceID = deviceID
        image = tmp.url.appendingPathComponent(deviceID + ".dmg")
        self.filesystem = filesystem
        let fs: String
        switch filesystem {
        case .fat32: fs = "MS-DOS FAT32"
        case .hfsPlus: fs = "HFS+"
        }
        // DJI Mic 3 と同じくパーティションの無い superfloppy にする
        try Self.run([
            "create", "-size", "\(sizeMB)m", "-fs", fs, "-volname", deviceID, "-layout", "NONE",
            image.path(percentEncoded: false),
        ])
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try attach(readOnly: false)
    }

    deinit {
        detach()
    }

    /// detach → attach（readOnly なら -readonly）
    public func reattach(readOnly: Bool) throws {
        detach()
        try attach(readOnly: readOnly)
    }

    /// hdiutil detach -force <mountPoint>（失敗は無視。自分が attach した mountPoint だけ）
    public func detach() {
        try? Self.run(["detach", "-force", mountPoint.path(percentEncoded: false)])
    }

    private func attach(readOnly: Bool) throws {
        var arguments = [
            "attach", "-nobrowse", "-noautoopen", "-noverify", "-mountpoint", mountPoint.path(percentEncoded: false),
        ]
        if readOnly { arguments.append("-readonly") }
        arguments.append(image.path(percentEncoded: false))
        try Self.run(arguments)
    }

    /// /usr/bin/hdiutil を起動し、終了コード 0 以外は DiskImageError（引数と stderr）を投げる
    private static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: hdiutil)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(decoding: errorData, as: UTF8.self)
            throw DiskImageError(description: "hdiutil " + arguments.joined(separator: " ") + ": " + message)
        }
    }
}

public struct DiskImageError: Error, CustomStringConvertible {
    public let description: String
}
