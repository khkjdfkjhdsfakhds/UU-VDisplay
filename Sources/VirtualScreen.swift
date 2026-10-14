import CoreGraphics
import Foundation

/// 用 CoreGraphics 私有类 CGVirtualDisplay 创建虚拟屏。
/// 对象释放即断开；进程退出时系统也会自动移除，不会残留。
final class VirtualScreen {
    private(set) var display: CGVirtualDisplay?
    var displayID: CGDirectDisplayID? { display?.displayID }
    var isConnected: Bool { display != nil }

    func connect(_ c: Config) -> Bool {
        if display != nil { return true }
        let d = CGVirtualDisplayDescriptor()
        d.name = c.name
        d.vendorID = c.vendorID
        d.productID = c.productID
        d.serialNum = c.serialNum
        let (w, h) = c.maxPixels
        d.maxPixelsWide = UInt32(w)
        d.maxPixelsHigh = UInt32(h)
        d.sizeInMillimeters = c.sizeInMillimeters
        // sRGB 色度坐标
        d.redPrimary = CGPoint(x: 0.64, y: 0.33)
        d.greenPrimary = CGPoint(x: 0.30, y: 0.60)
        d.bluePrimary = CGPoint(x: 0.15, y: 0.06)
        d.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        d.queue = DispatchQueue.main
        d.terminationHandler = { [weak self] _, _ in self?.display = nil }
        guard let vd = CGVirtualDisplay(descriptor: d) else { return false }
        display = vd
        return apply(c)
    }

    @discardableResult
    func apply(_ c: Config) -> Bool {
        guard let vd = display else { return false }
        let s = CGVirtualDisplaySettings()
        s.hiDPI = c.hiDPI ? 1 : 0
        s.modes = c.resolutions.filter { $0.count == 2 }.flatMap { r in
            c.refreshRates.map { CGVirtualDisplayMode(width: UInt32(r[0]), height: UInt32(r[1]), refreshRate: $0) }
        }
        return vd.apply(s)
    }

    func disconnect() { display = nil }

    // MARK: 模式

    /// 可用于桌面的模式，只保留与配置宽高比一致的，去重，按分辨率从大到小。
    func modes(_ c: Config) -> [CGDisplayMode] {
        guard let id = displayID else { return [] }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let all = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
        let (mw, mh) = c.maxPixels
        let aspect = Double(mw) / Double(mh)
        var seen = Set<String>()
        return all
            .filter { $0.isUsableForDesktopGUI() && abs(Double($0.width) / Double($0.height) - aspect) < 0.01 }
            .filter { seen.insert(Self.key($0)).inserted }
            .sorted { ($0.width, $0.pixelWidth, $0.refreshRate) > ($1.width, $1.pixelWidth, $1.refreshRate) }
    }

    static func key(_ m: CGDisplayMode) -> String {
        "\(m.width)x\(m.height)@\(Int(m.refreshRate.rounded()))@\(m.pixelWidth > m.width ? 1 : 0)"
    }

    static func sizeKey(_ m: CGDisplayMode) -> String {
        "\(m.width)x\(m.height)@\(m.pixelWidth > m.width ? 1 : 0)"
    }

    var currentMode: CGDisplayMode? { displayID.flatMap { CGDisplayCopyDisplayMode($0) } }

    @discardableResult
    func setMode(_ m: CGDisplayMode) -> Bool {
        guard let id = displayID else { return false }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(cfg, id, m, nil)
        // 只在本次会话生效：.permanently 会把当时的整套配置（包括镜像）写进系统，以后虚拟屏一出现就自动镜像。
        // 分辨率由本程序自己记住（State.modeKey）并在上线时恢复。
        return CGCompleteDisplayConfiguration(cfg, .forSession) == .success
    }
}

/// 远程模式：把其它物理屏镜像到虚拟屏，并让虚拟屏成为主屏。
/// 远程软件只会采集到一块 3:2 的屏，鼠标也不会跑到物理屏上。
/// 只在本次登录会话内生效；本程序退出或崩溃时虚拟屏消失，镜像随之自动解除，物理屏恢复正常。
enum Mirroring {
    static func physicalDisplays(excluding vid: CGDirectDisplayID) -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).filter { $0 != vid }
    }

    /// 正在独立显示的屏幕（硬件镜像中的从屏、关闭/休眠的屏幕都不算）
    static func activeDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return Array(ids.prefix(Int(n)))
    }

    /// 远程模式已生效：虚拟屏是主屏，且没有其它屏幕在独立显示（物理屏已镜像或已关闭都算）
    static func isRemoteActive(_ vid: CGDirectDisplayID) -> Bool {
        CGMainDisplayID() == vid && activeDisplays().allSatisfy { $0 == vid }
    }

    @discardableResult
    static func set(_ on: Bool, virtual vid: CGDirectDisplayID) -> Bool {
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
        // 开启时只镜像正在显示的屏幕（关闭/休眠的屏幕配置镜像会导致整次配置失败）
        let ids = on ? activeDisplays().filter { $0 != vid } : physicalDisplays(excluding: vid)
        for id in ids {
            CGConfigureDisplayMirrorOfDisplay(cfg, id, on ? vid : kCGNullDirectDisplay)
        }
        if on { CGConfigureDisplayOrigin(cfg, vid, 0, 0) }
        return CGCompleteDisplayConfiguration(cfg, .forSession) == .success
    }
}
