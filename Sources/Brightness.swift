import AppKit
import CoreGraphics

/// 组合亮度（硬件 + 软件）：
///   组合亮度 0.5…1.0 → 硬件亮度（DDC）0…100%，软件亮度 100%
///   组合亮度 0…0.5   → 硬件亮度 0，软件亮度（gamma 表缩放）0…100%
/// 软件调暗只改显示输出的 gamma，不加任何遮罩窗口，截图/远程画面不受影响。
final class Brightness {
    private let ddc = DDC()
    private var ddcMax = 100
    private var lastHardware: Int?
    private var original: [CGDirectDisplayID: ([CGGammaValue], [CGGammaValue], [CGGammaValue])] = [:]
    /// 软件亮度下限，避免完全黑屏
    private let minSoftware = 0.03
    var onChange: ((Double) -> Void)?

    var hasDDC: Bool { ddc != nil }

    private(set) var value: Double {
        get { UserDefaults.standard.object(forKey: "combinedBrightness") as? Double ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "combinedBrightness") }
    }

    init() {
        // 以显示器当前硬件亮度为准；若已在软件调暗区间（硬件为 0）则沿用上次的组合值
        if let ddc, let (cur, max) = ddc.readBrightness(), max > 0 {
            ddcMax = max
            lastHardware = cur
            if cur > 0 || value > 0.5 { value = 0.5 + Double(cur) / Double(max) / 2 }
        }
        target = value
        applySoftware()
        CGDisplayRegisterReconfigurationCallback({ _, flags, ctx in
            guard !flags.contains(.beginConfigurationFlag), let ctx else { return }
            let me = Unmanaged<Brightness>.fromOpaque(ctx).takeUnretainedValue()
            // 显示配置变化后系统会重置 gamma，稍后重新应用
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { me.displaysChanged() }
        }, Unmanaged.passUnretained(self).toOpaque())
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.displaysChanged() }
        }
    }

    /// 立即设置（菜单滑块：本身就是连续拖动）
    func set(_ v: Double) {
        animation?.invalidate()
        animation = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
        direction = 0
        target = min(1, max(0, v))
        apply(target, final: true)
    }

    // MARK: 丝滑过渡
    // 按下：立即走一档（1/16，对齐档位网格），约 0.15 秒缓出到位。
    // 按住：约 0.95 秒后开始自动重复，每 0.155 秒一档，每档同样带动画，看起来连续。
    // 松开：停止重复，当前这一档的动画走完。

    private var animation: Timer?
    private var repeatTimer: Timer?
    private var target: Double = 1
    private var from: Double = 1
    private var animStart = Date()
    private var direction = 0
    private var stepSize = 1.0 / 16
    private let stepDuration = 0.15
    private let repeatDelay = 0.95
    private let repeatInterval = 0.155

    func keyDown(up: Bool, fine: Bool) {
        let d = up ? 1 : -1
        if direction == d, repeatTimer != nil { return }
        direction = d
        stepSize = fine ? 1.0 / 64 : 1.0 / 16
        step()
        repeatTimer?.invalidate()
        let t = Timer(timeInterval: repeatDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.step()
            let r = Timer(timeInterval: self.repeatInterval, repeats: true) { [weak self] _ in self?.step() }
            RunLoop.main.add(r, forMode: .common)
            self.repeatTimer = r
        }
        RunLoop.main.add(t, forMode: .common)
        repeatTimer = t
    }

    func keyUp(up: Bool) {
        guard direction == (up ? 1 : -1) else { return }
        repeatTimer?.invalidate()
        repeatTimer = nil
        direction = 0
    }

    /// 以当前目标为基准走一档（连续时累加），对齐到档位网格
    private func step() {
        guard direction != 0 else { return }
        let base = animation == nil ? value : target
        let n = (base / stepSize).rounded() + Double(direction)
        let next = min(1, max(0, n * stepSize))
        if next == target, animation != nil { return }
        from = value
        target = next
        animStart = Date()
        guard animation == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        animation = t
    }

    private func tick() {
        let p = min(1, Date().timeIntervalSince(animStart) / stepDuration)
        let e = 1 - pow(1 - p, 3) // ease-out cubic
        let done = p >= 1
        apply(done ? target : from + (target - from) * e, final: done)
        if done {
            animation?.invalidate()
            animation = nil
        }
    }

    private func apply(_ v: Double, final: Bool) {
        value = v
        let hw = Int((max(0, v - 0.5) * 2 * Double(ddcMax)).rounded())
        if hw != lastHardware {
            lastHardware = hw
            ddc?.setBrightness(hw)
        }
        applySoftware()
        onChange?(v)
    }

    // MARK: 软件调暗（gamma）

    private lazy var virtualID: (UInt32, UInt32) = { let c = Config.load(); return (c.vendorID, c.productID) }()
    private var cachedTargets: [CGDirectDisplayID]?

    /// 物理外接屏（排除本程序的虚拟屏）；显示配置变化时刷新
    private var targets: [CGDirectDisplayID] {
        if let t = cachedTargets { return t }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        let t = ids.prefix(Int(n)).filter {
            CGDisplayIsBuiltin($0) == 0 && !(CGDisplayVendorNumber($0) == virtualID.0 && CGDisplayModelNumber($0) == virtualID.1)
        }
        cachedTargets = t
        return t
    }

    func displaysChanged() {
        cachedTargets = nil
        // 先恢复 ColorSync 原始 gamma，避免把已调暗的表当成原始值叠加
        if !original.isEmpty { CGDisplayRestoreColorSyncSettings() }
        original.removeAll()
        applySoftware()
    }

    func applySoftware() {
        let soft = min(1, value * 2)
        if soft >= 1 {
            if !original.isEmpty { CGDisplayRestoreColorSyncSettings() }
            original.removeAll()
            return
        }
        let k = CGGammaValue(minSoftware + (1 - minSoftware) * soft)
        for id in targets {
            if original[id] == nil {
                var r = [CGGammaValue](repeating: 0, count: 256), g = r, b = r
                var cnt: UInt32 = 0
                guard CGGetDisplayTransferByTable(id, 256, &r, &g, &b, &cnt) == .success, cnt > 0 else { continue }
                original[id] = (Array(r.prefix(Int(cnt))), Array(g.prefix(Int(cnt))), Array(b.prefix(Int(cnt))))
            }
            let (r, g, b) = original[id]!
            CGSetDisplayTransferByTable(id, UInt32(r.count), r.map { $0 * k }, g.map { $0 * k }, b.map { $0 * k })
        }
    }
}

/// 拦截键盘亮度键（系统定义事件 NX_KEYTYPE_BRIGHTNESS_UP/DOWN），改为调外接屏。需要“辅助功能”权限。
final class BrightnessKeys {
    private var tap: CFMachPort?
    private let brightness: Brightness
    private var retry: Timer?

    init(_ b: Brightness) {
        brightness = b
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) {
            install()
        } else {
            // 等用户在系统设置里授权
            retry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
                if AXIsProcessTrusted() { t.invalidate(); self?.install() }
            }
        }
    }

    var isActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    private func install() {
        let mask = CGEventMask(1 << 14) | CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, type, event, ctx in
            let me = Unmanaged<BrightnessKeys>.fromOpaque(ctx!).takeUnretainedValue()
            return me.handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// 功能键 keycode（F1–F20），只记录这些，不记录普通打字
    static let fnKeys: Set<Int64> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    /// 诊断日志：仅当 ~/Library/Logs/VDisplay.debug 存在时写入 ~/Library/Logs/VDisplay.log
    static func log(_ s: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("VDisplay.debug").path) else { return }
        let url = dir.appendingPathComponent("VDisplay.log")
        let line = "\(Date()) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown || type == .keyUp {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if type == .keyDown, Self.fnKeys.contains(code) { Self.log("keyDown F-key code=\(code) flags=\(event.flags.rawValue)") }
            // 罗技等非 Apple 键盘（经 Logi Options+）把亮度键发成 F14=调暗(107)、F15=调亮(113)
            guard code == 107 || code == 113 else { return Unmanaged.passUnretained(event) }
            let up = code == 113
            if type == .keyDown {
                // 系统按键重复（autorepeat）忽略，按住由自己的计时器连续调整
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    let fine = event.flags.contains([.maskAlternate, .maskShift])
                    DispatchQueue.main.async { [brightness] in brightness.keyDown(up: up, fine: fine) }
                }
            } else {
                DispatchQueue.main.async { [brightness] in brightness.keyUp(up: up) }
            }
            return nil
        }
        guard let ns = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
        if ns.type == .systemDefined { Self.log("systemDefined subtype=\(ns.subtype.rawValue) data1=0x\(String(ns.data1, radix: 16))") }
        guard ns.type == .systemDefined, ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let key = (ns.data1 & 0xFFFF_0000) >> 16
        let state = (ns.data1 & 0xFF00) >> 8   // 0x0A 按下 / 0x0B 松开
        let isRepeat = ns.data1 & 0x1 != 0
        guard key == 2 || key == 3 else { return Unmanaged.passUnretained(event) } // 2=亮度+ 3=亮度-
        if state == 0x0A, !isRepeat {
            let fine = ns.modifierFlags.contains([.option, .shift])
            DispatchQueue.main.async { [brightness] in brightness.keyDown(up: key == 2, fine: fine) }
        } else if state == 0x0B {
            DispatchQueue.main.async { [brightness] in brightness.keyUp(up: key == 2) }
        }
        return nil // 吞掉，避免系统再处理
    }
}
