# K40S 移植方案（对齐 UniXNU 官方八步法）

[English](02-porting-plan.md) | 简体中文

官方流程来自 https://unixnu.com/porting/steps 。下面每一步给出官方要求、本仓库的落地文件、以及验证状态。

## 步骤 1：收集设备输入

| 输入 | 值 | 来源 |
| --- | --- | --- |
| 代号 / 型号 | `munch` / `22021211RC`（K40S）、`22021211RG`（POCO F4） | Xiaomi 型号规则、LineageOS wiki |
| SoC | SM8250-AC (kona)，`qcom,msm-id = <0x164 0x20001>` | 厂商 DT |
| CPU | 4×A55 (cpu0-3) + 4×A77 (cpu4-7)，MPIDR 0x000–0x700 | `kona.dtsi` |
| 内存 | 起始 `0x80000000`；splash `0x9c000000+0x2300000` | `kona.dtsi` |
| 存储 | UFS `0x1d84000`，PHY `0x1d87000` | `kona.dtsi` |
| 触控 | FocalTech，`qupv3_se4_spi`，6 MHz，GPIO33 reset / GPIO39 IRQ | `munch-sm8250.dtsi` |
| 无线 | QCA6390 | `xiaomi-sm8250-common.dtsi` |
| 固件 | Mu-Silicium `SOC_TYPE=2`（SM8250-AC） | `uefi-alioth` |

落盘：`docs/CHANGES-from-alioth.md` 的对照表。

## 步骤 2：选择共享支持

| 层 | 选择 | 说明 |
| --- | --- | --- |
| ARM64 profile | `UniXNU/profiles/arch/arm64` | 官方公共补丁 |
| SoC | `FFT-infra/UniXNU-sm8250-common@a6e7e36` | 明确支持 SM8250-AC，含 SMP 补丁与 A650 GMU kit |
| OS | `ipados-17.7.11-21H461` | 仓库里唯一完整 profile；ADT 身份覆写为 iPhone10,3 |
| 设备 | 本仓库 | board/DTS/defconfig/archive |
| 固件 | `FFT-infra/uefi-alioth` + `uefi/` 覆盖层 | aliothPkg 已是 SM8250-AC |

## 步骤 3：创建设备仓库

官方布局全部具备：

```
board.toml                     # schema_version=2，munch 身份
feeds.toml                     # 固定 sm8250 与 ShengUfs
configs/munch_defconfig
dts/munch.dts
patches/xnu/series
package/                       # 板级服务与探针
kits/munch-touch/              # FocalTech 触控
proprietary-files.txt
porting.toml
uefi/                          # 本次新增：Mu-Silicium 平台覆盖层
unixnu.lock
```

与官方模板的差异：`uefi/` 不是官方规定目录，是“设备仓自带固件覆盖层”的折中做法，便于两仓互联；后续可提升为独立的 `uefi-munch` 仓库。

## 步骤 4：解析并检查构建

```sh
./unixnu defconfig munch_defconfig -D ../unixnu-munch
./unixnu fetch
./unixnu status --json
./unixnu tree
```

期望：`status` 显示 `soc=SM8250`、`soc_source=sm8250`、`os_profile=ipados-17.7.11-21H461`、设备包出现在 `tree/kits/munch/`。

## 步骤 5：硬件描述与固件

| 产物 | 来源 | 说明 |
| --- | --- | --- |
| XNU ADT | `dts/munch.dts` → `make-adt.py` | 由 payload 步骤生成 `kernel.macho.adt` |
| 固件 DTB | `uefi/Resources/DTBs/munch.dts` → `dtc` | 用于 `bootimg --dtb`，含 `cont_splash_region` |
| UEFI FD | `uefi/munchPkg/munch.dsc/.fdf` | 已包含 UniXNU、UniXNUDxe、UniXNURamDiskDxe、DarwinBoot、FAT/DiskIo |

`munch.dsc` 要点：

```ini
SOC_TYPE = 2                       # SM8250-AC
USE_CUSTOM_DISPLAY_DRIVER = 0      # 简易帧缓冲，不依赖面板 XML
gUniXNUPkgTokenSpaceGuid.PcdUniXNUDebugLevel|0x80000000
PcdCPUCoresStackBase|0x9FF90000
```

## 步骤 6：按依赖顺序适配驱动

| 子系统 | 本仓库实现 | 状态 |
| --- | --- | --- |
| 平台与内存 | `ArmDTPlatform` + `ArmCpu` + SM8250 DTSI | 沿用 alioth，地址已核对 |
| UFS | `ShengUfs`（`NativeUfs-alioth`） | 沿用，stream `0x0e0/0x4e0` |
| 显示 | `GopFramebuffer` / `build-gop-legacy-display.py` | 沿用，1080×2400 |
| 触控 | `kits/munch-touch` + `ShengHidInput` | 沿用，GPIO 待实测 |
| GPU | `build-adreno650.py` + A650 kit | 探针级，未完成 |
| Wi-Fi/音频/电源 | — | 未实现 |

## 步骤 7：构建并启动

```sh
./unixnu build kernel
./unixnu build package
./unixnu build firmware --uefi ../uefi-alioth
./unixnu build payload --unique-chip-id <hex> --trust-cache <bundle> --data-ramdisk <seed>
./unixnu bootimg --uefi ../uefi-alioth --dtb ../uefi-alioth/Resources/DTBs/munch.dtb
```

产出路径：`out/munch/ipados-17.7.11-21H461/munch_defconfig/{kernel,package,firmware,payload,boot}/`。
启动命令与检查点见 `03-real-device-test.md`。

## 步骤 8：完成并发布

- 设备仓已带 `.github/workflows/porting-record.yml`，推送后由 CI 校验 `porting.toml`。
- `porting.toml` 的 summary 已改为 munch 状态；各 area 的 evidence 仍来自 alioth，需在实机测试后逐项替换。
- 发布到 UniXNU 官方设备目录需要给仓库加 `unixnu` topic 并向官方提 PR；本次不自动执行。

## 与“成熟项目”的对应关系

| 参考 | 作用 |
| --- | --- |
| 小米平板 6S Pro（sheng，SM8550） | 官方最完整的移植：UEFI/DarwinBoot/显示/触控/GPU/Wi-Fi 全实现。本项目的 archive 结构、UEFI 模块组合、payload/ADT 约定均来自它 |
| Redmi K40（alioth，SM8250） | 同 SoC 的直接前身：内核配置、UFS root、GOP 显示、FocalTech 触控、USB 调试控制台 |
| Mi 10S（thyme，SM8250-AC） | 同为 SM8250-AC 的社区移植，验证了该 SoC 变体的可行性 |
