# unixnu-munch-build


[English](README.md) | 简体中文

Redmi K40S / POCO F4 (`munch`, SM8250-AC) 的**构建仓**：存放 GitHub Actions 流水线、固定输入和全部产出的镜像。

设备代码（board.toml、DTS、defconfig、内核归档脚本、UEFI 平台）在另一个仓库：

| 仓库 | 作用 |
| --- | --- |
| [WuBarlynn/unixnu-munch](https://github.com/WuBarlynn/unixnu-munch) | **代码仓**。设备描述、DTS、defconfig、archive 配方、`uefi/` 覆盖层 |
| [WuBarlynn/unixnu-munch-build](https://github.com/WuBarlynn/unixnu-munch-build) | **构建仓**（本仓库）。`build.yml` 流水线、固定输入、日志与镜像 Release |
| [FFT-infra/UniXNU](https://github.com/FFT-infra/UniXNU) | 构建驱动（含 QcomXnuUsbDebug 与 SM8250 支持的分支） `./unixnu`、组件目录、ARM64/OS profile |
| [FFT-infra/uefi-alioth](https://github.com/FFT-infra/uefi-alioth) | Mu-Silicium 基础固件（含 UniXNU 应用、RamDisk 驱动、DarwinBoot、SM8250 平台） |
| [FFT-infra/UniXNU-sm8250-common](https://github.com/FFT-infra/UniXNU-sm8250-common) | SM8250/SM8250-AC 公共资源、DTSI、内核配置片段 |

## 两个仓库如何互联

```
push 到 unixnu-munch (main)
        │
        ▼
GitHub Actions 手动触发 / 打 tag
        │
        ├── checkout 本仓库        → 流水线、config/unique-chip-id.txt
        ├── checkout unixnu-munch  → device/
        ├── checkout UniXNU        → unixnu/
        └── checkout uefi-alioth   → uefi/ + device/uefi/apply.sh 覆盖层
        │
        ▼
kernel → package → firmware → payload → boot.img → Release
```

- 流水线固定拉取 `WuBarlynn/unixnu-munch@main`（可在 `build.yml` 的 `env.DEVICE_REF` 改成别的分支/tag）。
- 设备仓的 `uefi/apply.sh` 把 `munchPkg`、`Resources/Configs/munch.toml`、`Resources/DTBs/munch.dts` 覆盖到 `uefi-alioth` 上并编译出 `munch.dtb`。
- 两边都不需要 PAT：全部使用 GitHub 官方的 `GITHUB_TOKEN` 只读拉取公开仓库。
- `config/unique-chip-id.txt` 是平台种子，必须保持稳定；改了它等于换了一台设备。

## 如何触发

1. 打开本仓库 **Actions → build-munch → Run workflow**。
2. `steps` 默认 `all`：
   - `kernel`：只编译内核（最快，用于验证工具链）。
   - `kernel-payload`：内核 + payload。
   - `boot-image`：在已有产物基础上打 boot.img。
   - `all`：内核、payload、UEFI 固件、boot.img 全做。
3. `userdata` 默认关闭：写 userdata 镜像需要约 20 GB 空闲磁盘，托管 macOS runner 可能不够；需要时用自托管 runner。
4. `release` 默认开启，产物会挂到 `build-<run_number>` 这个 Release 下。

也可以打 tag 触发：

```sh
git tag v0.1 && git push origin v0.1
```

## 产物

| 文件 | 路径（Release 内） | 说明 |
| --- | --- | --- |
| `boot.img` | `out/munch/ipados-17.7.11-21H461/munch_defconfig/boot/boot.img` | 一次性启动用：`fastboot boot boot.img` |
| `SILICIUM_UEFI.fd` | `.../firmware/` | UEFI 固件卷，已含 UniXNU/DarwinBoot |
| `payload.img` | `.../payload/` | FAT payload：unixnu.toml + kernel.macho + ADT + 信任缓存 + Data seed |
| `kernel.macho` / `.adt` | `.../kernel/` | 预链接内核与 Apple 设备树 sidecar |
| `userdata-root.img` | `.../userdata/` | 仅在 `userdata=true` 时生成 |
| `*.log` / `status.json` | `.../logs/`、根目录 | 构建记录与依赖解析结果 |

> **法律提示**：`kernel.macho`、`payload.img`、`boot.img`、`userdata-root.img` 含 Apple IPSW 派生内容（kernelcache、trust cache、OS 镜像）。请把本仓库保持为 **private**，不要公开分发这些文件。

## 本地复现

```sh
git clone --recurse-submodules https://github.com/FFT-infra/UniXNU
git clone https://github.com/WuBarlynn/unixnu-munch
git clone --recurse-submodules https://github.com/FFT-infra/uefi-alioth

unixnu-munch/uefi/apply.sh "$PWD/uefi-alioth"

cd UniXNU
./unixnu defconfig munch_defconfig -D ../unixnu-munch
./unixnu fetch && ./unixnu tree
./unixnu build kernel
./unixnu build package
./unixnu build firmware --uefi ../uefi-alioth
./unixnu build payload --unique-chip-id 7248a912881f43a1 \
    --trust-cache build/original-static-system-trust/original-static-system.bundle \
    --data-ramdisk build/owner-data-fixture/owner-data-3.dbr
./unixnu bootimg --uefi ../uefi-alioth --dtb ../uefi-alioth/Resources/DTBs/munch.dtb
```

`build-original-system-trust.py` 与 `prepare-owner-data-fixture.py` 只能在 macOS 上跑；Linux 可完成 kernel/package/firmware/bootimg。

## 文档

| 文档 | 内容 |
| --- | --- |
| [docs/01-feasibility.md](docs/01-feasibility.zh-CN.md) | 可行性评估：证据、阻塞项、结论 |
| [docs/02-porting-plan.md](docs/02-porting-plan.zh-CN.md) | 八步移植方案与本次实现映射 |
| [docs/03-real-device-test.md](docs/03-real-device-test.zh-CN.md) | 实机分步测试手册（解锁、备份、刷写、日志、回滚） |
| [docs/04-troubleshooting.md](docs/04-troubleshooting.zh-CN.md) | 故障排查与已知限制 |
