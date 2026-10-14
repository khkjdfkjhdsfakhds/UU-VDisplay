# UU-VDisplay

一个 macOS 菜单栏小工具：用平板等设备通过 **UU 远程**控制 Mac 时，自动创建一块与平板比例一致的虚拟屏并切换过去，让控制端**满屏**显示；断开后自动还原。附带外接显示器的亮度控制（DDC + 软件调暗）和键盘亮度键支持。

A macOS menu-bar utility that creates a virtual display matching your tablet's aspect ratio and switches to it automatically while a UU Remote session is active, so the remote view fills the tablet screen. Also provides external-monitor brightness control (DDC/CI + software dimming) with keyboard brightness keys.

## 功能

- **虚拟屏**：基于 `CGVirtualDisplay`，可自定义名称、尺寸、分辨率、刷新率，支持 HiDPI。
- **远程模式**：把物理屏镜像到虚拟屏，虚拟屏成为主屏。远程软件只会看到一块屏，比例与平板一致。
- **UU 连入自动切换**：检测到 UU 远程会话后约 4 秒自动进入远程模式，断开约 5 秒后还原（虚拟屏若是自动创建的会一并移除）。
- **外接屏亮度**：
  - 组合亮度：50%–100% 通过 DDC/CI 调显示器硬件亮度，0–50% 继续用 gamma 表软件调暗至接近全黑。
  - 软件调暗只改显示输出的 gamma，不加遮罩窗口，不影响截图、录屏和远程画面。
  - 支持键盘亮度键（标准亮度键，以及部分键盘发出的 F14/F15），单击调一档，按住连续调整，带平滑过渡。
- **登录时启动**。

## 要求

- Apple Silicon Mac（DDC 通过 `IOAVService`，仅支持 Apple Silicon）
- macOS 14 及以上（在 macOS 27 上开发测试）
- Xcode 命令行工具（`swiftc`）

## 构建与安装

```bash
./build.sh            # 生成 build/VDisplay.app
./build.sh --install  # 同时安装到 /Applications 并替换旧版本
```

`build.sh` 默认 ad-hoc 签名。若钥匙串里有名为 `VDisplay Local Signing` 的代码签名证书，会优先使用它；签名固定后，重新编译不会让“辅助功能”授权失效。

亮度键需要在 **系统设置 → 隐私与安全性 → 辅助功能** 中允许 VDisplay。

## 配置

配置文件：`~/Library/Application Support/VDisplay/config.json`（菜单里可直接打开编辑）。

| 字段 | 说明 |
|---|---|
| `name` | 虚拟屏名称 |
| `sizeInch` | 对角线尺寸（英寸），影响系统默认缩放 |
| `resolutions` | 模式列表。最大的一项决定虚拟屏最大像素；开启 HiDPI 时，想要“看起来像 W×H”的 HiDPI 模式就直接写 `[W, H]` |
| `refreshRates` | 刷新率列表 |
| `hiDPI` | 是否启用 HiDPI |
| `vendorID` / `productID` / `serialNum` | 虚拟屏标识，保持不变时系统会记住它的排列和色彩描述文件 |

默认配置适合 3:2、约 12.5 英寸的平板（最大 3200×2136，含 1600×1068 / 1440×960 / 1280×854 / 1200×800 HiDPI）。

## 工作原理与已知限制

- **UU 会话检测**：每秒统计一次 `UURemoteServer` 进程的网络 socket 数量（空闲时 ≤4，有会话时 ≥17，阈值 6），连续 4 秒超过阈值判定为连入，连续 5 秒低于阈值判定为断开。UU 刚连上的 1–2 秒内切换屏幕会被控制端错过，所以有意延迟约 4 秒。
- **远程中切换分辨率**：UU 会记录会话开始时那块屏的分辨率，中途改变会导致会话断流。因此远程中切换分辨率时会移除虚拟屏并以新分辨率重建（约 2 秒），等同于一次新的自动切换。仍可能偶发卡顿，建议在连接前选好分辨率。
- 分辨率切换只在当前登录会话内生效，由本程序自己记住并在虚拟屏上线时恢复；不写入系统永久显示配置。
- 使用了 macOS 私有接口（`CGVirtualDisplay`、`IOAVService`），系统更新后可能失效。
- 自动切换的判定记录在 `~/Library/Logs/VDisplay-UU.log`，便于排查。

## 测试

```bash
./test.sh   # 端到端测试：创建虚拟屏、切换分辨率、远程模式、亮度读写，结束自动还原（会影响屏幕约 1 分钟）
```

## License

MIT
