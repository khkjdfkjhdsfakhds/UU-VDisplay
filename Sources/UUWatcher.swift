import Darwin
import Foundation

/// 检测 UU 远程是否有人连入。
/// 实测：空闲时 UURemoteServer 只有 1 个网络 socket；有远程会话时为 17–21 个（并伴随明显 CPU 占用）。
/// 每 1 秒数一次 socket（单次约 0.3 ms）。
/// 连入：连续 4 次（约 4 秒）超过阈值才切换。实测在 UU 刚连上的 1–2 秒内切换屏幕，
/// UU 正在建立会话、会错过这次变化，控制端停留在原来的比例而不满屏；等 3–4 秒再切则稳定满屏。
/// 断开：连续 5 次（约 5 秒）低于阈值，避免网络抖动误判。
final class UUWatcher {
    var onChange: ((Bool) -> Void)?
    private(set) var connected = false
    private var timer: Timer?
    private var streak = 0
    private let threshold = 6

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        streak = 0
    }

    private func poll() {
        let count = Self.socketCount(process: "UURemoteServer") ?? 0
        let active = count >= threshold
        if active == connected {
            streak = 0
            return
        }
        streak += 1
        if streak >= (active ? 4 : 5) {
            streak = 0
            connected = active
            Self.log("UU \(active ? "连入" : "断开")（socket=\(count)）")
            onChange?(active)
        }
    }

    static func pid(named name: String) -> pid_t? {
        var pids = [pid_t](repeating: 0, count: 4096)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var buf = [CChar](repeating: 0, count: 256)
        for p in pids.prefix(Int(max(0, n))) where p > 0 {
            if proc_name(p, &buf, UInt32(buf.count)) > 0, String(cString: buf) == name { return p }
        }
        return nil
    }

    static func socketCount(process name: String) -> Int? {
        guard let p = pid(named: name) else { return nil }
        let size = proc_pidinfo(p, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let got = proc_pidinfo(p, PROC_PIDLISTFDS, 0, &fds, size)
        guard got > 0 else { return nil }
        // 只数 IPv4/IPv6 网络 socket（排除本地 unix socket）
        var n = 0
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var si = socket_fdinfo()
            let r = proc_pidfdinfo(p, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, Int32(MemoryLayout<socket_fdinfo>.size))
            if r > 0, si.psi.soi_family == AF_INET || si.psi.soi_family == AF_INET6 { n += 1 }
        }
        return n
    }

    /// 每次判定切换写一行到 ~/Library/Logs/VDisplay-UU.log，便于排查误判
    static func log(_ s: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VDisplay-UU.log")
        let line = "\(Date()) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
}
