// hdiutil の FAT32（または HFS+）イメージを一時ディレクトリにマウントする（.diskImage のテストだけが使う）。
// /Volumes の下には決してマウントしない（利用者の実機 /Volumes/DJIMIC3 と衝突させない）。
import Darwin
import Foundation
import VDContract

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
        try Self.refuseUnsafe(tmp: tmp.url, deviceID: deviceID)
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

    /// hdiutil detach -force <mountPoint>（失敗は無視。自分が attach した mountPoint だけ）。
    /// mountPoint が実際にマウント点になっているとき（statfs の f_mntonname が realpath と一致）だけ hdiutil を起動する。
    public func detach() {
        let path = mountPoint.path(percentEncoded: false)
        guard let resolved = Self.realpath(path) else { return }
        var st = statfs()
        guard statfs(resolved, &st) == 0 else { return }
        let mountedOn = withUnsafeBytes(of: st.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard mountedOn == resolved else { return }
        try? Self.run(["detach", "-force", path])
    }

    /// 実機に触れ得る入力を hdiutil を起動する前に拒む（PLAN §10.2）:
    /// deviceID が DeviceID の規則外、`DJIMIC3`（実機と同じ名前）、一時ディレクトリの realpath が /Volumes の下。
    static func refuseUnsafe(tmp: URL, deviceID: String) throws {
        guard DeviceID.isValid(deviceID) else {
            throw DiskImageError(description: "DiskImageVolume: 不正な deviceID: \(deviceID)")
        }
        guard deviceID != "DJIMIC3" else {
            throw DiskImageError(description: "DiskImageVolume: 実機と同じ名前 DJIMIC3 は使わない")
        }
        guard let root = realpath(tmp.path(percentEncoded: false)) else {
            throw DiskImageError(description: "DiskImageVolume: 一時ディレクトリの realpath が取れない")
        }
        guard root != "/Volumes", !root.hasPrefix("/Volumes/") else {
            throw DiskImageError(description: "DiskImageVolume: 一時ディレクトリが /Volumes の下にある: \(root)")
        }
    }

    private static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
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
