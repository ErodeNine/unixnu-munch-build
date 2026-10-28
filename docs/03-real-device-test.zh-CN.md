# K40S 实机测试手册（逐步执行）

[English](03-real-device-test.md) | 简体中文

> 适用：Redmi K40S / POCO F4（`munch`），SM8250-AC。
> 前置：**已解锁 Bootloader**。未解锁请先在“小米社区 → 解锁工具”完成申请（通常需等待 168 小时）。
> 风险：解锁会清空数据；刷 `userdata` 会再次清空。**A 阶段用 `fastboot boot`，不改任何分区**，此阶段可随时长按电源键回滚。

测试分三阶段，按顺序做，不要跳步：

| 阶段 | 动作 | 破坏性 | 目标 |
| --- | --- | --- | --- |
| A | `fastboot boot boot.img` | 无 | UEFI 菜单、DarwinBoot、XNU 控制台 |
| B | `fastboot flash boot_a/boot_b` | 可回滚 | 断电重启仍能进 UniXNU |
| C | `fastboot flash userdata` | **清空数据** | iOS Data 卷挂载、进入用户态 |

> 阶段 1 镜像（v0.9 起）：没有显示后端，也没有触控驱动。屏幕上是 `build-boot-progress.py`
> 在内核帧缓冲上绘制的启动阶段文本与 panic；UEFI 菜单仍可用音量键/电源键或 USB 键盘操作；
> 内核日志从 USB CDC-ACM 输出。锁屏、壁纸与触控属于阶段 2。
>
> **可用镜像：** build-18（tag `v0.18`）的 `boot.img` 为 178.4 MB，A/B 阶段只需要它。
> C 阶段暂无 Release 镜像（完整 userdata 分区约 226 GiB），需先在本地生成该镜像。

---

## 0. 准备清单

- Windows/Linux/macOS 主机 + `platform-tools`（adb/fastboot）。
- 原装或质量可靠的 USB-C 数据线。
- 电量 ≥ 50%。
- 下载对应版本的**官方 fastboot ROM**（munch），用于回滚：`munch_images_*.tgz`（小米官网/XDA）。
- 一台能保存日志的电脑（A 阶段开始后 USB 会重新枚举）。

检查工具：

```sh
adb version
fastboot --version
```

---

## 1. 设备核对与备份

### 1.1 进入 fastboot

关机后按住 **音量下 + 电源**，出现兔子界面即进入 fastboot。

```sh
fastboot devices
fastboot getvar product          # 期望：munch
fastboot getvar current-slot     # a 或 b
fastboot getvar partition-size:boot_a
fastboot getvar partition-size:boot_b
fastboot getvar partition-size:userdata
fastboot getvar unlocked         # 期望：yes
```

记录下表（后续所有镜像参数以此为准）：

| 项 | 值 | 用途 |
| --- | --- | --- |
| product |  | 必须 `munch`，否则停止 |
| current-slot |  | B 阶段刷哪个 slot |
| boot_a 字节 |  | 确认 ≥ 192 MiB |
| boot_b 字节 |  | 同上 |
| userdata 字节 |  | 计算 LBA，见 1.3 |

### 1.2 备份原厂 boot / dtbo（强烈建议）

有 root（Magisk/KernelSU）时，开机后执行：

```sh
adb shell su -c 'dd if=/dev/block/by-name/boot_a of=/sdcard/boot_a.img'
adb shell su -c 'dd if=/dev/block/by-name/boot_b of=/sdcard/boot_b.img'
adb shell su -c 'dd if=/dev/block/by-name/dtbo of=/sdcard/dtbo.img'
adb pull /sdcard/boot_a.img
adb pull /sdcard/boot_b.img
adb pull /sdcard/dtbo.img
```

没有 root 时，用官方 fastboot ROM 里的 `boot.img` 作为回滚镜像（推荐至少准备这一份）。

### 1.3 计算 userdata 的 LBA

`board.toml` 里的 `first_lba/last_lba` 必须与真机 GPT 一致。取 `fastboot getvar partition-size:userdata` 的字节数：

```
first_lba ≈ 分区起始扇区（需从 GPT 读，见下）
last_lba  = floor(分区字节数 / 4096) + first_lba - 1
```

读取 GPT（root）：

```sh
adb shell su -c 'sgdisk -p /dev/block/sda' | grep userdata
# 或
adb shell su -c 'parted /dev/block/sda unit s print' | grep userdata
```

把结果填入 `unixnu-munch/board.toml` 的 `[userdata]`，重新构建 payload/boot，否则 C 阶段会写错位置。

### 1.4 提取原厂 DT（用于替换 alioth 派生的固件 DTB）

```sh
# dtbo 分区里是 overlay，boot 分区里是基础 DT；先用 magiskboot 解包
magiskboot unpack boot_a.img          # 生成 kernel / ramdisk / dtb
dtc -I dtb -O dts dtb -o munch-stock.dts
```

把 `munch-stock.dts` 与 `uefi/Resources/DTBs/munch.dts` 对比，重点核对：
`qcom,board-id`（K40S 为 `<0x32 0x00>`）、`/memory`、`/reserved-memory/cont_splash_region`。
确认后替换 `uefi/Resources/DTBs/munch.dts` 并重新构建，这是 P0 阶段最值得先做的一步。

---

## A 阶段：非破坏性启动

```sh
fastboot boot path/to/boot.img
```

`fastboot boot` 只把镜像加载进内存，不写分区；失败时设备会自动重启回 Android。

### A1 期望现象（按顺序）

| # | 检查点 | 现象 | 失败时看 |
| --- | --- | --- | --- |
| A1 | UEFI 初始化 | 屏幕保持小米 logo/黑屏数秒后出现 UniXNU 菜单 | 一直黑屏 → 固件未跑起来（见 4.1） |
| A2 | 菜单 | 屏上有 `Boot` 条目，倒计时 3 秒 | 有菜单无条目 → payload 未被发现（4.2） |
| A3 | DarwinBoot | 选择后出现 UniXNU/DarwinBoot 文本或彩色条 | 卡住 → 4.3 |
| A4 | XNU 控制台 | 屏幕出现内核日志、`Darwin Kernel Version` | panic → 拍照记录（4.4） |
| A5 | 根卷 | 日志出现 UFS/IOMedia/root 相关行 | 见 4.5 |

### A2 按键操作

- 音量加/减移动，电源键确认（`ButtonsDxe` 已把电源键映射为 ENTER）。
- 若按键无效：插 **USB 键盘**，用方向键+回车操作（固件包含 UsbKbDxe）。

### A3 抓日志（关键）

系统启动后，USB 会重新枚举为 CDC-ACM 串口（VID:PID `1209:316d`，名 `QcomXnuUsbDebug`）：

- Linux：`dmesg | tail` 找到 `/dev/ttyACM0`，然后
  `picocom -b 115200 /dev/ttyACM0 | tee munch-boot-$(date +%s).log`
- Windows：设备管理器确认 COM 号，用 PuTTY（Serial，115200 8N1）保存日志。
- macOS：`screen /dev/tty.usbmodem* 115200`，`Ctrl-A` `H` 记录。

日志里必须有（按顺序）：

```
UNIXNU: ...            # 固件/菜单
DARWINBOOT: ...        # 交接
Darwin Kernel Version  # 内核
TOUCH start=1          # 触控探针（若带 native-touch=1）
```

把日志和屏幕照片一起存档，填入第 5 节记录表。

---

## B 阶段：写入 boot 分区（可选）

A 阶段连续三次能到 A4 再做。

```sh
fastboot flash boot_a boot.img
# 如果 current-slot=b 且希望从 b 启动：
fastboot flash boot_b boot.img
fastboot --set-active=b
```

**回滚**：

```sh
fastboot flash boot_a stock-boot.img
fastboot flash boot_b stock-boot.img
```

或直接 `fastboot reboot`，再用官方 ROM 的 `flash_all.bat` 全量恢复。

---

## C 阶段：安装 userdata（危险，最后做）

只在 B 阶段稳定、且已核对 1.3 的 LBA 后执行。

```sh
fastboot flash userdata userdata-root.img
```

耗时较长（数 GB）。完成后重启，观察日志中：

- APFS 容器/卷出现；
- `launchd` 启动；
- Data 卷挂载结果。

失败特征与对应处理见 4.5/4.6。

---

## 4. 故障分支

### 4.1 A1 黑屏/无菜单

1. 确认 `fastboot getvar product` 是 `munch`。
2. 确认用的是 `boot.img` 而不是 `SILICIUM_UEFI.fd`。
3. 换用 alioth 的 `Binaries/alioth` 与 `Binaries/munch` 逐项对比；若仍黑屏，说明厂商 DXE 不兼容，需要按 D2 提取 K40S 自己的 DXE。
4. 检查 `boot.json`（Release 产物里）中的 `ramdisk_bytes` 是否非 0。

### 4.2 有菜单但没有 Boot 条目

说明 UEFI 没找到 payload 的 FAT 卷：

- `boot.json` 的 `ramdisk_bytes` 必须是 176 MiB 左右；
- 固件 FDF 必须包含 `UniXNURamDiskDxe`、`DiskIoDxe`、`Fat`；
- 串口日志应有 `UNIXNURAMDISK: initrd block device`。

### 4.3 卡在 DarwinBoot

- 90% 是 payload 里的 `kernel.macho.adt` 与 `kernel.macho` 不匹配，或 `unixnu.toml` 条目缺失；
- 重新 `./unixnu build payload` 后重新 `bootimg`，两者必须同批次。

### 4.4 内核 panic

拍下 panic 屏，或在串口日志里找 `panic(cpu ...)` 首行。常见：

| panic | 含义 | 处理 |
| --- | --- | --- |
| `rootvp not authenticated after mounting` | owner root 信任链未生效 | 确认 `CONFIG_XNU_OWNER_ROOT_TRUST=y`、trust cache 正确 |
| `offline scratch Data mount failed: 2` | Data 卷未通过 RamBlock 发布 | 确认 `CONFIG_XNU_NATIVE_RAM_BLOCK=y` 且 payload 带 Data seed |
| `Invalid kernel stack pointer` | 从核 SMP 拓扑补丁缺失 | 确认 `native-smp-secondary.patch`、`native-smp-type-clusters.patch` 在 SoC series 中 |

### 4.5 UFS/根卷失败

- 检查 DTS `&ufs`、`&ufsphy` 为 `okay`；
- 检查启动参数 `native-ufs-stream=0xe0`、`native-ufs-stream2=0x4e0`、`native-ufs-root=1`；
- 若日志显示 UFS 链路起不来，先退回 B 阶段的 Android 系统确认硬件正常。

### 4.6 触控无反应

`kits/munch-touch` 的复位脚记录为 GPIO 101，而 munch 厂商 DT 是 GPIO 33。二者必有一个不适用于你的批次：先看串口 `TOUCH start=1` 与 `contacts=` 计数，再决定是否改 `FocalTouchBoard.h`。

---

## D2（进阶）：提取 K40S 自己的厂商 DXE

> 只有 A1 失败或充电/按键异常时才需要。

1. 从官方 fastboot ROM 解出 `xbl.elf`（或 root 后 `dd if=/dev/block/by-name/xbl`）。
2. 用 [UEFITool](https://github.com/LongSoft/UEFITool) 打开，查找 DXE 驱动卷。
3. 按 `Binaries/alioth/QcomPkg/Drivers/<Name>/` 的目录结构，把同名 `.efi`、`.depex` 放到 `Binaries/munch/...`（`.inf` 可直接复用 alioth 的，`FILE_GUID` 与 `BASE_NAME` 不变）。
4. `uefi/apply.sh` 在 `Binaries/munch` 已存在时不会覆盖，改完重新构建固件即可。

---

## 5. 记录表（每次测试复制一份）

| 项 | 内容 |
| --- | --- |
| 日期/构建号 |  |
| 设备型号/代号 |  |
| 内存容量 | 6 / 8 / 12 GiB |
| current-slot |  |
| boot.img md5 |  |
| 到达检查点 | A1 / A2 / A3 / A4 / A5 |
| 关键日志 |  |
| panic 首行 |  |
| 屏幕照片 |  |
| 下一步 |  |

---

## 6. 一键收集环境信息（可选）

```sh
cat > collect-munch.sh <<'EOF'
#!/usr/bin/env bash
set -e
echo "== date"; date -u
echo "== fastboot"; fastboot getvar all 2>&1 | grep -E "product|slot|partition-size|unlocked|version"
echo "== adb"; adb devices -l
echo "== usb"; lsusb 2>/dev/null | grep -i -E "1209|qualcomm|xiaomi" || true
EOF
chmod +x collect-munch.sh
```
