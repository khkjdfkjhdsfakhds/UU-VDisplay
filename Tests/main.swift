// 晚上运行：./test.sh  —— 会让屏幕闪烁、短暂切换布局，结束后自动还原。
import AppKit

func step(_ s: String) { print("▶︎", s); fflush(stdout) }
func wait(_ t: Double) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }
func check(_ ok: Bool, _ what: String) { print(ok ? "  ✅" : "  ❌", what); fflush(stdout) }

let c = Config.load()
let vs = VirtualScreen()

step("1. 创建虚拟屏 \(c.name)")
check(vs.connect(c), "CGVirtualDisplay 创建")
wait(2)
guard let vid = vs.displayID else { exit(1) }
check(CGDisplayIsOnline(vid) != 0, "displayID \(vid) 在线")

step("2. 列出 3:2 模式")
for m in vs.modes(c) { print("   \(m.width)×\(m.height) px \(m.pixelWidth)×\(m.pixelHeight) @\(Int(m.refreshRate))") }

step("3. 切换到 2400×1602 @120，再切回 1600×1068 HiDPI")
if let m = vs.modes(c).first(where: { $0.width == 2400 && Int($0.refreshRate) == 120 }) {
    check(vs.setMode(m), "设置 2400×1602"); wait(2)
    check(vs.currentMode?.width == 2400, "当前宽度 = \(vs.currentMode?.width ?? 0)")
}
if let m = vs.modes(c).first(where: { $0.width == 1600 && $0.pixelWidth == 3200 && Int($0.refreshRate) == 120 }) {
    check(vs.setMode(m), "设置 1600×1068 HiDPI"); wait(2)
}

step("4. 远程模式：物理屏镜像到虚拟屏，虚拟屏成为主屏")
check(Mirroring.set(true, virtual: vid), "镜像配置提交"); wait(3)
check(Mirroring.isRemoteActive(vid), "远程模式已生效")
check(CGMainDisplayID() == vid, "主屏 = 虚拟屏（实际 \(CGMainDisplayID())）")
print("   主屏尺寸：\(CGDisplayBounds(CGMainDisplayID()))")
print("   👉 此时可用 UU 远程连一下，看是否 3:2 满屏（30 秒后自动还原）"); wait(30)

step("5. 退出远程模式")
check(Mirroring.set(false, virtual: vid), "取消镜像"); wait(3)
check(!Mirroring.isRemoteActive(vid), "远程模式已退出")

step("6. 外接屏亮度：+10 → 还原")
if let d = DDC(), let (cur, mx) = d.readBrightness() {
    d.setBrightness(min(cur + 10, mx)); wait(1.5)
    check(d.readBrightness()?.0 == min(cur + 10, mx), "亮度变为 \(min(cur + 10, mx))")
    d.setBrightness(cur); wait(1.5)
    check(d.readBrightness()?.0 == cur, "亮度还原为 \(cur)")
} else { check(false, "DDC 不可用") }

step("7. 断开虚拟屏")
vs.disconnect(); wait(2)
print("   （本测试进程的显示缓存不会刷新，断开结果请以 系统设置/system_profiler 为准）")
