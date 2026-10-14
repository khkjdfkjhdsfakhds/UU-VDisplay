import Foundation
import IOKit

/// Apple Silicon 上通过 IOAVService 走 DDC/CI 调外接显示器硬件亮度（VCP 0x10）。
final class DDC {
    private let service: IOAVService
    private let queue = DispatchQueue(label: "ddc")
    private let lock = NSLock()
    private var pending: Int?

    /// 找第一个外接显示器的 DCPAVServiceProxy（假设只有一台外接屏）。
    init?() {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var found: IOAVService?
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            let loc = IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if loc == "External", let av = IOAVServiceCreateWithService(kCFAllocatorDefault, s) {
                found = av
                break
            }
        }
        guard let f = found else { return nil }
        service = f
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(0x6E ^ 0x51, ^)
    }

    /// 读取 (当前值, 最大值)。同步调用，约 50–150ms。
    func readBrightness() -> (Int, Int)? {
        queue.sync {
            var req: [UInt8] = [0x82, 0x01, 0x10]
            req.append(Self.checksum(req))
            var out = [UInt8](repeating: 0, count: 12)
            for _ in 0..<4 {
                IOAVServiceWriteI2C(service, 0x37, 0x51, &req, UInt32(req.count))
                usleep(40_000)
                guard IOAVServiceReadI2C(service, 0x37, 0x51, &out, UInt32(out.count)) == kIOReturnSuccess else { continue }
                if out[2] == 0x02, out[3] == 0, out[4] == 0x10 {
                    return (Int(out[8]) << 8 | Int(out[9]), Int(out[6]) << 8 | Int(out[7]))
                }
                usleep(40_000)
            }
            return nil
        }
    }

    /// 异步写入；拖动滑块时只发送最新值，避免堆积。
    func setBrightness(_ value: Int) {
        lock.lock()
        let idle = pending == nil
        pending = value
        lock.unlock()
        guard idle else { return }
        queue.async { [self] in
            while true {
                lock.lock()
                guard let v = pending else { lock.unlock(); return }
                lock.unlock()
                var cmd: [UInt8] = [0x84, 0x03, 0x10, UInt8(v >> 8), UInt8(v & 0xFF)]
                cmd.append(Self.checksum(cmd))
                IOAVServiceWriteI2C(service, 0x37, 0x51, &cmd, UInt32(cmd.count))
                usleep(20_000)
                lock.lock()
                if pending == v {
                    pending = nil
                    lock.unlock()
                    // 最终值再写一次，防止偶发丢包
                    usleep(30_000)
                    IOAVServiceWriteI2C(service, 0x37, 0x51, &cmd, UInt32(cmd.count))
                    return
                }
                lock.unlock()
            }
        }
    }
}
