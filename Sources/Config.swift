import Foundation

/// 虚拟屏配置，保存在 ~/Library/Application Support/VDisplay/config.json，可手动编辑。
struct Config: Codable {
    var name = "VDisplay"
    var sizeInch = 12.5
    /// 模式尺寸。最大的一项决定虚拟屏最大像素（3200×2136 → 自动有 1600×1068 HiDPI）。
    /// 开启 HiDPI 时，想要“看起来像 W×H”的 HiDPI 模式，就直接写 W×H（实测：写像素尺寸如 2880×1920 不会生成可用的 1440×960 HiDPI）。
    var resolutions: [[Int]] = [[3200, 2136], [2400, 1602], [1600, 1068], [1440, 960], [1280, 854], [1200, 800]]
    var refreshRates: [Double] = [144, 120, 60]
    var hiDPI = true
    // 虚拟屏的显示器标识。保持不变时 macOS 会把它认作同一台显示器（记住排列与色彩描述文件）。
    var vendorID: UInt32 = 0x5644
    var productID: UInt32 = 0x0001
    var serialNum: UInt32 = 1

    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VDisplay", isDirectory: true)
    static let url = dir.appendingPathComponent("config.json")

    static func load() -> Config {
        if let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(Config.self, from: data) {
            return c
        }
        let c = Config()
        c.save()
        return c
    }

    func save() {
        try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Config.url)
    }

    /// 物理尺寸（毫米），按最大分辨率的宽高比由对角线英寸换算。
    var sizeInMillimeters: CGSize {
        let (w, h) = maxPixels
        let diag = sizeInch * 25.4
        let k = diag / (Double(w * w + h * h)).squareRoot()
        return CGSize(width: Double(w) * k, height: Double(h) * k)
    }

    var maxPixels: (Int, Int) {
        let r = resolutions.filter { $0.count == 2 }.max { $0[0] * $0[1] < $1[0] * $1[1] } ?? [1920, 1080]
        return (r[0], r[1])
    }
}

/// 运行状态（上次是否连接、选的模式），存 UserDefaults。
enum State {
    static var connected: Bool {
        get { UserDefaults.standard.bool(forKey: "connected") }
        set { UserDefaults.standard.set(newValue, forKey: "connected") }
    }
    /// "宽x高@刷新率@HiDPI"，如 "1600x1068@120@1"
    static var modeKey: String? {
        get { UserDefaults.standard.string(forKey: "modeKey") }
        set { UserDefaults.standard.set(newValue, forKey: "modeKey") }
    }
}
