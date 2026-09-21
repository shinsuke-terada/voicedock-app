// posix_spawn の薄い包み。新しいプロセスグループ・CLOEXEC_DEFAULT・stdin は /dev/null（PLAN §8.2）。
import Darwin
import Foundation

struct SpawnedChild: Sendable {
    let pid: pid_t  // = プロセスグループの ID（SETPGROUP で 0 を指定）
    let stdoutFD: Int32  // 親が読む口
    let stderrFD: Int32
}

enum Spawn {
    static func start(_ spec: ProcessSpec) -> Result<SpawnedChild, SpawnError> {
        let path = spec.executable.path(percentEncoded: false)
        guard isValid(spec, path: path) else { return .failure(.spawnFailed(errno: EINVAL)) }

        var out: [Int32] = [-1, -1]
        var err: [Int32] = [-1, -1]
        if pipe(&out) != 0 { return .failure(.pipeFailed(errno: errno)) }
        if pipe(&err) != 0 {
            let code = errno
            close(out[0])
            close(out[1])
            return .failure(.pipeFailed(errno: code))
        }
        _ = fcntl(out[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(err[0], F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attr, Int16(flags))
        posix_spawnattr_setpgroup(&attr, 0)  // 新しいグループ（pgid = 子の pid）
        var defaults: sigset_t = ~0  // 全シグナルを既定の動作に戻す（アプリが無視している SIGPIPE などを子に持ち込まない）
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var mask: sigset_t = 0  // シグナルマスクを空に
        posix_spawnattr_setsigmask(&attr, &mask)

        let argv = [path] + spec.arguments
        let envp = spec.environment.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }
        var pid: pid_t = 0
        let rc = withCStringArray(argv) { argvPointers in
            withCStringArray(envp) { envpPointers in
                posix_spawn(&pid, path, &actions, &attr, argvPointers, envpPointers)
            }
        }

        close(out[1])
        close(err[1])
        if rc != 0 {
            close(out[0])
            close(err[0])
            return .failure(.spawnFailed(errno: rc))
        }
        return .success(SpawnedChild(pid: pid, stdoutFD: out[0], stderrFD: err[0]))
    }

    /// 手順 1 の指定の検査（相対パス・NUL・= を含むか空の環境変数名を拒む）
    private static func isValid(_ spec: ProcessSpec, path: String) -> Bool {
        guard spec.executable.isFileURL, path.hasPrefix("/") else { return false }
        let nul = "\u{0}"
        if path.contains(nul) || spec.arguments.contains(where: { $0.contains(nul) }) { return false }
        for (key, value) in spec.environment {
            if key.isEmpty || key.contains("=") || key.contains(nul) || value.contains(nul) { return false }
        }
        return true
    }

    /// strdup した C 文字列の配列（末尾に nil）を body に渡し、呼び出しの後で free する
    static func withCStringArray<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
        let pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) } + [nil]
        defer { for pointer in pointers { free(pointer) } }
        return body(pointers)
    }
}
