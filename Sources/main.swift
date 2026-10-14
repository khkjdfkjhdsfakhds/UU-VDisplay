import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config = Config.load()
    private let screen = VirtualScreen()
    private var brightness: Brightness!
    private var keys: BrightnessKeys!
    private var statusItem: NSStatusItem!
    private var brightnessLabel: NSTextField?
    private var brightnessSlider: NSSlider?
    /// 用户开启了远程模式：镜像被打断（虚拟屏刚上线、UU 重连等）时自动恢复
    private var remoteWanted = false
    private var ensuring = false
    private var modeReady = false
    private let uu = UUWatcher()
    /// 本次远程模式是否由 UU 连入自动开启；以及开启前虚拟屏是否已连接（断开时据此还原）
    private var autoEngaged = false
    private var virtualWasConnected = false
    private var autoUU: Bool {
        get { UserDefaults.standard.object(forKey: "autoUU") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoUU") }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "VDisplay")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        brightness = Brightness()
        brightness.onChange = { [weak self] v in
            self?.brightnessSlider?.doubleValue = v * 100
            self?.brightnessLabel?.stringValue = Self.brightnessText(v)
        }
        keys = BrightnessKeys(brightness)

        if State.connected { connect() }

        uu.onChange = { [weak self] on in self?.uuChanged(on) }
        if autoUU { uu.start() }

        CGDisplayRegisterReconfigurationCallback({ _, flags, ctx in
            guard !flags.contains(.beginConfigurationFlag), let ctx else { return }
            let me = Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { me.ensureMirror() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// UU 有人连入 → 自动进入远程模式；断开 → 还原到连入前的状态
    private func uuChanged(_ on: Bool) {
        if on {
            guard !remoteWanted else { return }
            virtualWasConnected = screen.isConnected
            autoEngaged = true
            remoteWanted = true
            ensureMirror()
        } else {
            guard autoEngaged else { return }
            autoEngaged = false
            remoteWanted = false
            if let id = screen.displayID { Mirroring.set(false, virtual: id) }
            if !virtualWasConnected {
                screen.disconnect()
                State.connected = false
            }
        }
    }

    @objc private func toggleAutoUU() {
        autoUU.toggle()
        if autoUU { uu.start() } else { uu.stop() }
    }

    /// 远程模式开启时，反复尝试直到镜像真正生效（最多约 10 秒）
    private func ensureMirror(attempt: Int = 0) {
        guard remoteWanted, !ensuring || attempt > 0 else { return }
        if !screen.isConnected { connect(persist: !autoEngaged) }
        // 分辨率还没恢复好就先不镜像；restoreMode 完成后会再调用这里
        guard modeReady, let id = screen.displayID else { ensuring = false; return }
        if Mirroring.isRemoteActive(id) {
            ensuring = false
            return
        }
        ensuring = true
        // 不弹窗（远程时弹窗会挡住操作）；之后任何显示配置变化都会再次尝试
        if attempt >= 20 {
            ensuring = false
            return
        }
        Mirroring.set(true, virtual: id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in ensureMirror(attempt: attempt + 1) }
    }

    private static func brightnessText(_ v: Double) -> String {
        let hw = Int((max(0, v - 0.5) * 200).rounded())
        return "外接屏亮度：\(Int((v * 100).rounded()))%" + (v < 0.5 ? "（软件调暗）" : "（硬件 \(hw)%）")
    }

    func applicationWillTerminate(_ note: Notification) {
        if let id = screen.displayID { Mirroring.set(false, virtual: id) }
        screen.disconnect()
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let connected = screen.isConnected

        let title = NSMenuItem(title: "虚拟屏：\(config.name)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(item(connected ? "断开虚拟屏" : "连接虚拟屏", #selector(toggleConnect)))

        if connected {
            menu.addItem(resolutionMenu())
            menu.addItem(refreshMenu())
        }

        menu.addItem(.separator())
        let remote = item("远程模式（其它屏幕镜像到虚拟屏）", #selector(toggleRemote))
        remote.state = remoteWanted ? .on : .off
        menu.addItem(remote)
        let auto = item("UU 连入时自动切换", #selector(toggleAutoUU))
        auto.state = autoUU ? .on : .off
        menu.addItem(auto)

        menu.addItem(.separator())
        menu.addItem(brightnessItem())
        if !keys.isActive {
            let k = item("亮度键未启用：点此打开辅助功能权限", #selector(openAccessibility))
            menu.addItem(k)
        }

        menu.addItem(.separator())
        menu.addItem(item("添加自定义分辨率…", #selector(addResolution)))
        menu.addItem(item("编辑配置文件…", #selector(editConfig)))
        menu.addItem(item("重新载入配置", #selector(reloadConfig)))
        let login = item("登录时启动", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("退出", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func resolutionMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "分辨率", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let cur = screen.currentMode
        var seen = Set<String>()
        for m in screen.modes(config) where seen.insert(VirtualScreen.sizeKey(m)).inserted {
            let hidpi = m.pixelWidth > m.width
            let i = item("\(m.width) × \(m.height)" + (hidpi ? "  HiDPI" : ""), #selector(pickResolution(_:)))
            i.representedObject = VirtualScreen.sizeKey(m)
            if let c = cur, VirtualScreen.sizeKey(c) == VirtualScreen.sizeKey(m) { i.state = .on }
            sub.addItem(i)
        }
        root.submenu = sub
        return root
    }

    private func refreshMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "刷新率", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if let cur = screen.currentMode {
            let rates = screen.modes(config)
                .filter { VirtualScreen.sizeKey($0) == VirtualScreen.sizeKey(cur) }
                .map { Int($0.refreshRate.rounded()) }
            for r in Array(Set(rates)).sorted(by: >) {
                let i = item("\(r) Hz", #selector(pickRefresh(_:)))
                i.representedObject = r
                if Int(cur.refreshRate.rounded()) == r { i.state = .on }
                sub.addItem(i)
            }
        }
        root.submenu = sub
        return root
    }

    private func brightnessItem() -> NSMenuItem {
        let i = NSMenuItem()
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 48))
        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 18, y: 26, width: 230, height: 16)
        label.font = .menuFont(ofSize: 13)
        let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: self, action: #selector(brightnessChanged(_:)))
        slider.frame = NSRect(x: 16, y: 4, width: 230, height: 20)
        slider.isContinuous = true
        v.addSubview(label)
        v.addSubview(slider)
        i.view = v
        brightnessLabel = label
        brightnessSlider = slider

        slider.doubleValue = brightness.value * 100
        label.stringValue = Self.brightnessText(brightness.value)
        if !brightness.hasDDC { label.stringValue += " · DDC 不可用" }
        return i
    }

    // MARK: 动作

    /// persist：是否记住“虚拟屏已连接”（UU 自动开启时不记，重启后不会无故出现虚拟屏）
    private func connect(persist: Bool = true) {
        if screen.isConnected { return }
        guard screen.connect(config) else {
            alert("创建虚拟屏失败", "CGVirtualDisplay 返回空。请确认没有其他虚拟显示器工具正在使用相同标识的虚拟屏。")
            return
        }
        if persist { State.connected = true }
        modeReady = false
        restoreMode()
    }

    /// 新屏上线后立即切到保存的分辨率（系统默认会给 1280×854），完成后才允许开镜像，
    /// 这样 UU 切过来时看到的就是最终分辨率，不会因中途改分辨率而卡住。
    private func restoreMode(attempt: Int = 0) {
        guard screen.isConnected else { return }
        let modes = screen.modes(config)
        let cur = screen.currentMode.map(VirtualScreen.key)
        let target = State.modeKey.flatMap { key in modes.first { VirtualScreen.key($0) == key } }
        // 等到模式列表可用，且当前模式确实已是保存的模式（系统切换模式是异步生效的）
        if attempt < 40, modes.isEmpty || (target != nil && cur != State.modeKey) {
            if let t = target, cur != State.modeKey, attempt % 5 == 0 { screen.setMode(t) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in restoreMode(attempt: attempt + 1) }
            return
        }
        UUWatcher.log("虚拟屏就绪，模式 \(cur ?? "?")（用时 \(attempt * 100) ms）")
        modeReady = true
        ensureMirror()
    }

    @objc private func toggleConnect() {
        if screen.isConnected {
            remoteWanted = false
            if let id = screen.displayID { Mirroring.set(false, virtual: id) }
            screen.disconnect()
            State.connected = false
        } else {
            connect()
        }
    }

    @objc private func toggleRemote() {
        autoEngaged = false
        if remoteWanted {
            remoteWanted = false
            if let id = screen.displayID { Mirroring.set(false, virtual: id) }
            return
        }
        remoteWanted = true
        ensureMirror()
    }

    private func applyMode(sizeKey: String, refresh: Int?) {
        let cands = screen.modes(config).filter { VirtualScreen.sizeKey($0) == sizeKey }
        let want = refresh ?? screen.currentMode.map { Int($0.refreshRate.rounded()) }
        guard let m = cands.first(where: { Int($0.refreshRate.rounded()) == want }) ?? cands.first else { return }
        State.modeKey = VirtualScreen.key(m)
        // 远程中直接改分辨率会让 UU 会话断开：UU 记录会话开始时那块屏的分辨率，中途改变就断流，
        // 断开后还会把分辨率改回去。UU 能稳定处理的是“出现一块新屏”，所以远程中改分辨率时
        // 直接移除虚拟屏、以新分辨率重建（等同于刚连入时的自动切换）。
        if remoteWanted, screen.isConnected {
            UUWatcher.log("远程中切换分辨率 → \(State.modeKey ?? "?")：重建虚拟屏")
            if let id = screen.displayID { Mirroring.set(false, virtual: id) }
            screen.disconnect()
            modeReady = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                if !screen.isConnected { connect(persist: !autoEngaged) }
            }
            return
        }
        screen.setMode(m)
    }

    @objc private func pickResolution(_ sender: NSMenuItem) {
        guard let k = sender.representedObject as? String else { return }
        applyMode(sizeKey: k, refresh: nil)
    }

    @objc private func pickRefresh(_ sender: NSMenuItem) {
        guard let r = sender.representedObject as? Int, let cur = screen.currentMode else { return }
        applyMode(sizeKey: VirtualScreen.sizeKey(cur), refresh: r)
    }

    @objc private func brightnessChanged(_ sender: NSSlider) {
        brightness.set(sender.doubleValue / 100)
    }

    @objc private func addResolution() {
        let a = NSAlert()
        a.messageText = "添加自定义分辨率"
        a.informativeText = "输入分辨率，如 1440x960。\n开启 HiDPI 时会得到“看起来像”该尺寸的 HiDPI 模式（字更大更清晰）。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "2560x1600"
        a.accessoryView = field
        a.addButton(withTitle: "添加")
        a.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let nums = field.stringValue.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard nums.count == 2, nums[0] >= 640, nums[1] >= 480 else {
            alert("格式不对", "请输入 宽x高，例如 2560x1600。")
            return
        }
        if !config.resolutions.contains(nums) { config.resolutions.append(nums) }
        config.save()
        reapply(maxChanged: true)
    }

    @objc private func editConfig() {
        config.save()
        NSWorkspace.shared.open(Config.url)
    }

    @objc private func reloadConfig() {
        config = Config.load()
        reapply(maxChanged: true)
    }

    /// 最大分辨率或标识改变时必须重建虚拟屏；否则直接更新模式。
    private func reapply(maxChanged: Bool) {
        guard screen.isConnected else { return }
        if maxChanged {
            screen.disconnect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                connect()
                ensureMirror()
            }
        } else {
            screen.apply(config)
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("设置登录启动失败", error.localizedDescription)
        }
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
