# 红米 K40S（munch）UniXNU 移植可行性评估

日期：2026-10-28
结论先行：**技术上可行，且属于当前最有利的一类移植**——同 SoC 已有可运行到内核/显示/触控阶段的参考移植（alioth），K40S 的关键硬件与它逐项一致。但“完整启动 iOS 到桌面”仍受上游工程进度与两个仅 macOS 可完成的输入限制，不能承诺一次成功。

## 1. 证据来源

| 来源 | 用途 | 关键结论 |
| --- | --- | --- |
| https://unixnu.com/ 全站文档（经 20122 SOCKS5 代理抓取） | 架构、八步移植法、构建命令、设备仓库规范 | 六层启动栈；`./unixnu defconfig/fetch/tree/build/bootimg` 是唯一构建入口 |
| https://unixnu.com/devices/munch | 是否已有 munch 移植 | **HTTP 404**，官方设备目录中没有 K40S |
| `FFT-infra/UniXNU-sm8250-common@a6e7e36` | SoC 公共支持 | `soc.toml` 明确覆盖 **SM8250 / SM8250-AC (kona)**；含 GICv3、timer、UFS、QUPv3、A650 GMU kit、SMP 补丁 |
| `FFT-infra/UniXNU-alioth@c567d24` | 同代参考设备仓库 | 完整 archive 链、UFS root、GOP 显示、FocalTech SE4 触控、USB 调试控制台 |
| `FFT-infra/uefi-alioth@d2710c6` | Mu-Silicium 基础固件 | `aliothPkg` 中 `SOC_TYPE = 2` 即 SM8250-AC；`USE_CUSTOM_DISPLAY_DRIVER = 0`（简易帧缓冲，不需要面板初始化） |
| LineageOS `android_kernel_xiaomi_sm8250` 的 `kona.dtsi`、`munch-sm8250.dtsi` | K40S 真实硬件描述 | splash `0x9c000000+0x2300000`；UFS `0x1d84000`；触控 SE4 / 6 MHz / reset GPIO 33 / IRQ GPIO 39；QCA6390 |

## 2. 硬件对照（K40S vs alioth）

| 项目 | K40S (munch) | Redmi K40 (alioth) | 是否复用 |
| --- | --- | --- | --- |
| SoC | SM8250-AC (kona) | SM8250 / -AC | ✅ 同一 SoC 仓库 |
| CPU | 4×A55 + 4×A77 | 同 | ✅ |
| 内存起点 | `0x80000000`，6/8/12 GiB | 同，6/8/12 GiB | ✅ |
| 显示 | 1080×2400 AMOLED 120 Hz | 1080×2400 AMOLED 120 Hz | ✅ GOP 简易帧缓冲 |
| splash 保留区 | `0x9c000000` + `0x2300000` | 同 | ✅ 逐字节一致 |
| 存储 | UFS 3.1 `0x1d84000` / PHY `0x1d87000` | 同 | ✅ 同一 UFS 驱动，stream `0x0e0/0x4e0` |
| 触控 | FocalTech on GENI SE4，6 MHz，GPIO33/39 | 同 | ✅ 同一驱动路径（复位脚待实测确认） |
| Wi-Fi/BT | QCA6390 | QCA6390 | ⚠️ 驱动未实现（不影响内核启动） |
| 充电 | 67 W（BQ2597x/QC30 等） | 33 W | ❌ 电源域不同，属后续工作 |
| 面板 IC | munch 专属 AMOLED | alioth 专属 | ⚠️ 仅影响自定义显示驱动；当前用简易帧缓冲 |

结论：**除充电/面板/相机外，K40S 在启动链所需的外设上与 alioth 高度同构**。这决定了可以复用 alioth 的内核配置、archive 配方与显示/触控路径。

## 3. 可行性分级

| 阶段 | 依赖 | 预判 | 依据 |
| --- | --- | --- | --- |
| P0 UEFI 固件启动、出菜单 | munchPkg + 厂商 DXE | **高** | aliothPkg 已是 SM8250-AC；内存图与 K40S `kona.dtsi` 完全一致 |
| P1 DarwinBoot 交接、XNU 进入内核 | kernel.macho + ADT + payload | **高** | alioth 已实现并实测到内核；K40S 沿用同一配置 |
| P2 UFS 根卷发布 | ShengUfs + verified root | **中高** | alioth 已 device-verified；K40S 同 UFS host |
| P3 显示/触控 | GOP + FocalTech | **中** | alioth 已实现；K40S 面板/触控批次不同，需实测 |
| P4 到 SpringBoard/桌面 | Data 卷、trust cache、GPU | **中低** | alioth 自身仍在打通 Data 卷与 GPU；K40S 继承同一上限 |
| P5 GPU/Metal、Wi-Fi、音频、电源 | A650、QCA6390、DSP | **低（本期）** | 上游组件未完成，非本次范围 |

## 4. 已知阻塞项

1. **厂商 UEFI DXE 二进制**：K40S 没有现成 dump。当前用 `Binaries/alioth`（同为 SM8250 参考集）作为引导，需实机确认；提取方法见 `03-real-device-test.md` D2。
2. **固件 DTB**：`Resources/DTBs/munch.dtb` 由 alioth 的反编译 DT 改写 `model` 与 `qcom,board-id=0x32` 得到；最佳做法是从 K40S 的 `dtbo`/`boot` 分区提取原厂 DT 替换。
3. **userdata LBA**：`board.toml [userdata]` 仍沿用 alioth 的扇区范围，刷写前必须用 `fastboot getvar partition-size:userdata` 与 GPT 核对。
4. **Data 卷种子**：官方脚本依赖 macOS `hdiutil` 创建 APFS；已改为 GitHub Actions macOS runner 生成。
5. **上游完成度**：alioth 的 GPU/网络/音频/电源仍是 planned；即使一切顺利，K40S 首轮目标应设为“UEFI 菜单 → 内核控制台 → 根卷”，而不是完整 iOS 桌面。

## 5. 结论

- **移植可行性：可行**，且风险低于普通新设备，因为 SoC 与关键外设均有同代参考实现。
- **本次交付**：完整设备仓库（`unixnu-munch`）、UEFI 平台覆盖层（`uefi/`）、构建流水线与全部文档。
- **实机目标**：先验证 P0–P2，再逐项推进 P3–P4；不以“一次点亮 iOS”作为验收前提。
