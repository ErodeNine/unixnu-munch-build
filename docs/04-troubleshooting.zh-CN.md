# 已知限制与排查

[English](04-troubleshooting.md) | 简体中文

## 1. 继承自 alioth 的上限

本移植的 archive 链、内核配置与板级服务来自 `UniXNU-alioth`。该参考设备的 porting 记录（2026-10-28 修订）为：

| 区域 | alioth 状态 |
| --- | --- |
| CPU / 中断 | implemented |
| 存储与根卷 | device-verified（UFS 可读，根卷受 owner 策略保护） |
| 显示 | implemented（GOP，锁屏可显示） |
| 输入 | implemented（FocalTech 帧读取正常，HID 发布待验证） |
| GPU / 网络 / 音频 / 电源 | planned |

因此 K40S 的合理预期是：**UEFI → 菜单 → DarwinBoot → XNU 控制台 → UFS 根卷 → 可能到锁屏**；GPU/Metal、Wi-Fi、音频不在本期能力范围内。

## 2. 两个仅 macOS 的步骤

| 步骤 | 原因 | 当前方案 |
| --- | --- | --- |
| `prepare-owner-data-fixture.py` | 用 `hdiutil` 创建 APFS 容器 | GitHub Actions `macos-26` |
| `seed-data-grow.py` | `diskutil apfs resizeContainer` | 同上 |
| `build-original-system-trust.py` | 需要完整 IPSW 与 macOS 解压 | 同上 |

Linux 可完成 kernel（需先跑 `scripts/linux/setup-toolchain.py`）、package、firmware、bootimg、userdata。

## 3. 磁盘

- IPSW ≈ 7 GB；OS/SystemOS dmg 各 ≈ 4 GB；userdata 镜像 ≈ 8 GB。
- 托管 `macos-26` runner 约 14 GB 空闲，**全量构建会不够**。流水线默认不构建 userdata。
- 需要 userdata 时：用自托管 runner（`runs-on: [self-hosted, macOS]`）或更大的 runner。

## 4. 厂商固件

- `Binaries/munch` 当前是 `Binaries/alioth` 的副本（同一 SM8250 参考集）。
- 如果 UEFI 阶段黑屏/按键异常，按 `03-real-device-test.md` D2 提取 K40S 自己的 DXE。
- `Resources/DTBs/munch.dtb` 由 alioth 反编译 DT 改写而来；最优是替换为原厂 boot 分区里的 DT。

## 5. 常见构建错误

| 错误 | 原因 | 处理 |
| --- | --- | --- |
| `board.example = true` | 模板仓库未完成 | 本仓库没有该字段，忽略 |
| `defconfig: unknown fragment` | `config_fragments` 指向不存在的文件 | 检查 `soc:configs/sm8250.config` 是否存在 |
| `fetch: repository not found` | `feeds.toml` 的 URL 失效 | 本仓库已把 `NativeUfs-munch` 改回 `NativeUfs-alioth` |
| `check-munch: Binaries/munch inputs are missing` | 没跑 `uefi/apply.sh` | 先应用覆盖层 |
| `munch.dtb is missing` | 没编译 DT | `apply.sh` 会调用 `dtc` |
| `hdiutil: attach failed` | dmg 未解压或被占用 | 重新执行 `extract-target-volume.py OS` |
| `Require the unchanged supplied original OS mount` | OS 卷不是目标 IPSW 的 | 确认 17.7.11 / 21H461 |

## 6. 调试通道

| 通道 | 何时可用 | 读取方式 |
| --- | --- | --- |
| 屏幕（GOP） | 从 UEFI 开始 | 拍照 |
| USB CDC-ACM | 内核启动后 | `/dev/ttyACM0` 115200 8N1 |
| 二维码日志 | 本平台未集成 | — |
| UART | K40S 无外露 | — |

## 7. 合规

- 产物包含 Apple IPSW 派生数据，仓库应保持 private。
- 不要分发 `userdata-root.img`、`kernel.macho`、`payload.img`。
- 本项目不绕过 Apple 的激活/签名服务；仅用于自有机型的系统移植研究。

## GUI 边界（2026-10-29 实测）

带显示与触控 archive 的镜像在实机上到达用户态：

- `/private/var`、`launchd`、`keybagd`、`usermanagerd`、`datamigrator` 均退出码 0；
- 显示后端报告 `DISPLAY stage=10 PM=4 calls=4 callbacks=1`，面板出现诊断彩条，
  说明 `IOMobileFramebufferLegacy` 已注册且有客户端；
- `SpringBoard` 被反复拉起，并在同一 PC 以 `sig5 ns=2 code=5` 崩溃，即 FrontBoard 的
  断言 `failed to find the main CADisplay`；
- 串口里完全没有 `backboardd`，也没有 `IOGPU`/`Metal`/`AGX` 活动。

SpringBoard 通过 CoreDisplay 索取主 CADisplay；该显示器由 backboardd 在帧缓冲之上发布，
而 iOS 17 的渲染服务器依赖 Metal 设备。没有 Adreno 650 加速器提供者就没有 Metal 设备，
GUI 层停在这里。这就是 `docs/01-feasibility.md` 里的 P5（GPU/Metal）项。
