# 在本地 macOS 上构建

[English](05-local-macos.md) | 简体中文

这是 GitHub Actions 流水线的本地替代：在你自己的 Mac 上产出同样的 `kernel.macho`、
`UniXNU.efi`、`SILICIUM_UEFI.fd`、`payload.img` 与 `boot.img`。流水线保留作备用。

## 1. 环境要求

| 项 | 值 |
| --- | --- |
| macOS | 13 及以上；内核步骤需要带 iOS 17 SDK 的 Xcode |
| Xcode | 15 及以上（CI 用 26.x）；先执行一次 `sudo xcode-select -s /Applications/Xcode.app` |
| Python | 3.11 及以上（`python3 --version`） |
| Homebrew | `brew install llvm lld mtools dtc unifdef cmake ninja` |
| GitHub token | 先 `gh auth login`，或导出 `GITHUB_TOKEN`；内核步骤通过 API 列 Apple 源码，匿名调用会触发 HTTP 403 限流 |
| 磁盘 | 约 30 GB 空闲：IPSW 成员 8.5 GB、构建树与内核约 8 GB、启动镜像 0.2 GB |
| 时间 | 首次 40–90 分钟；保留 `out/` 的增量重建 10–20 分钟 |

`openssl`、`git`、`hdiutil` 系统自带。Apple Silicon 与 Intel 均可，脚本会自动识别 Homebrew 前缀。

## 2. 一条命令

```sh
git clone https://github.com/WuBarlynn/unixnu-munch-build
cd unixnu-munch-build
chmod +x scripts/build-local.sh
./scripts/build-local.sh ~/munch-build
```

脚本会：

1. 在 `~/munch-build` 下克隆/更新 `UniXNU`、`device`、`uefi`（目录名固定：设备仓的 kit 软链接指向 `../../UniXNU/kits`）；
2. 对固件树执行 `device/uefi/apply.sh`；
3. 解析配置并组装构建树；
4. 用 HTTP Range 读取 IPSW 成员（不下载 6.6 GB 整包）；
5. 生成信任缓存 bundle、Data 种子与两份 owner 策略；
6. 把生成的 Data 种子 UUID 写回 defconfig；
7. 依次构建 kernel、package、firmware、payload、boot image。

重复执行脚本就是增量构建：源码与内核构建树保留在 `~/munch-build/UniXNU/out`，只重建变化部分。

## 3. 手工分步

脚本出错、想逐步观察时用这一节。

```sh
WORK=~/munch-build
mkdir -p "$WORK" && cd "$WORK"
git clone --recurse-submodules https://github.com/FFT-infra/UniXNU.git UniXNU
git clone https://github.com/WuBarlynn/unixnu-munch.git device
git clone --recurse-submodules https://github.com/FFT-infra/uefi-alioth.git uefi

device/uefi/apply.sh "$WORK/uefi"          # 安装 munchPkg、配置、DTB、二进制覆盖层

cd UniXNU
./unixnu defconfig munch_defconfig -D ../device
./unixnu fetch
./unixnu status --json
./unixnu tree
```

拉取链路需要的三个 IPSW 成员：

```sh
./unixnu ipsw fetch OS Cryptex1,SystemOS StaticTrustCache Cryptex1,SystemTrustCache
```

信任缓存 bundle（两个原始模块合成一个 bundle）：

```sh
VOL=.cache/firmware/target-volumes && mkdir -p "$VOL"
python3 ../unixnu-munch-build/scripts/prepare-trust-module.py \
  out/ipsw/21H461/044-76040-038.dmg.trustcache "$VOL/static-trustcache.bin" \
  da88460e6e513438d5307e5c526f76497a74754476a24da29f239f0c90120fc2
python3 ../unixnu-munch-build/scripts/prepare-trust-module.py \
  out/ipsw/21H461/044-76034-038.dmg.trustcache "$VOL/system-trustcache.bin" \
  d121ba89167e03aafd00fa687c30cd8ebc4ccafd10c1408adb2ba3de12403651
```

Data 种子与 owner 策略需要挂载 OS 卷：

```sh
mkdir -p "$VOL/os-mount"
hdiutil attach -readonly -nobrowse -owners off -mountpoint "$VOL/os-mount" \
  out/ipsw/21H461/044-76040-038.dmg
python3 scripts/prepare-owner-data-fixture.py
OUT=out/munch/ipados-17.7.11-21H461/munch
python3 ../unixnu-munch-build/scripts/build-root-policy.py --component os \
  --dmg out/ipsw/21H461/044-76040-038.dmg --out "$OUT/tree/build/verified-root-os" \
  --expected-sha256 3f99b859c9728379110b66657c7b15285bcb1925ad8b5726542e2cdcf8b1028d \
  --expected-blocks 1483785 --expected-uuid 04769D26-2CA0-4825-B443-E2E5F88300F2 \
  --mountpoint "$VOL/os-mount" --image-source disk
hdiutil detach "$VOL/os-mount" -force || true
python3 ../unixnu-munch-build/scripts/build-root-policy.py --component systemos \
  --dmg out/ipsw/21H461/044-76034-038.dmg --out "$OUT/tree/build/verified-root-systemos" \
  --expected-sha256 b4908cde41d23e6bc05e6af51a2c9eeb00cf0f863a6a18b1600c96a3fd70414f \
  --expected-blocks 806400 --image-source file
mkdir -p build
python3 ../unixnu-munch-build/scripts/pack-data-seed.py \
  build/owner-data-fixture/owner-data-32.cdr build/owner-data-fixture/owner-data-32.dbr
python3 scripts/seed-data-grow.py --gib 3 \
  build/owner-data-fixture/owner-data-32.dbr build/owner-data-fixture/owner-data-3.dbr
```

写入种子 UUID 后开始构建：

```sh
UUID=$(python3 -c "import json;print(json.load(open('build/owner-data-fixture/seed.json'))['volume_uuid'])")
# 把 ../device/configs/munch_defconfig 里的 CONFIG_XNU_OWNER_DATA_VOLUME_UUID 改成 $UUID
./unixnu defconfig munch_defconfig -D ../device

for d in libsa libkern osfmk bsd pexpert iokit security; do
  mkdir -p "$OUT/tree/build/xnu/ios-obj/EXPORT_HDRS/$d"
done
export UNIXNU_UEFI=$WORK/uefi

./unixnu build kernel   # 第一遍：链接占位 sheng_pmgr_run
./unixnu build kernel   # 第二遍：拿到参考内核后链接真正的 ApplePMGR 桥
./unixnu build package
./unixnu build firmware --uefi "$WORK/uefi"
./unixnu build payload --unique-chip-id "$(cat ../unixnu-munch-build/config/unique-chip-id.txt)" \
  --trust-cache build/original-static-system-trust/original-static-system.bundle \
  --data-ramdisk build/owner-data-fixture/owner-data-3.dbr
./unixnu bootimg --uefi "$WORK/uefi" --dtb "$WORK/uefi/Resources/DTBs/munch.dtb"
```

## 4. 产物位置

都在 `out/munch/ipados-17.7.11-21H461/munch/` 下：

| 路径 | 内容 |
| --- | --- |
| `kernel/kernel.macho` | 预链接内核（内嵌两份策略表，约 120 MB） |
| `package/Build/Out/` | `UniXNU.efi`、`UniXNUDxe.efi`、`UniXNURamDiskDxe.efi` |
| uefi 检出目录的 `Build/munchPkg/DEBUG_CLANGPDB/FV/SILICIUM_UEFI.fd` | 固件卷 |
| `payload/payload.img` | 176 MiB FAT payload |
| `boot/boot.img` | 用于实机测试的镜像 |

## 5. 重建与清理

- 更新源码：`git -C ~/munch-build/device pull`（`UniXNU`、`uefi` 同理），再重跑脚本。
- 改配置：编辑 `device/board.toml` 或 `device/configs/munch_defconfig` 后重跑，脚本会重新 `defconfig` 与 `tree`。
- 彻底清理：`cd ~/munch-build/UniXNU && ./unixnu clean`（保留已拉取源码）；删除 `out/` 则从头构建。
- 只重建固件：跑到 `build firmware` 后，再执行一次 `./unixnu bootimg --uefi ... --dtb ...`（payload 会自动取 `out/.../payload/payload.img`）。

## 6. 常见问题

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `xcodebuild: error: SDK "iphoneos" cannot be located` | 没有选中 Xcode | `sudo xcode-select -s /Applications/Xcode.app` |
| `ld.lld: command not found` | Homebrew 的 lld 不在 PATH | `brew install lld`；脚本会把 `$(brew --prefix llvm)/bin` 加进 PATH |
| `hdiutil: attach failed - Resource busy` | OS 卷已挂载 | `hdiutil detach .cache/firmware/target-volumes/os-mount -force` 后重试 |
| `Require the unchanged supplied original OS mount` | IPSW 成员不是 17.7.11/21H461 | 用 `./unixnu ipsw info` 核对 |
| `No space left on device` | 构建期间可用空间不足 10 GB | 清理磁盘；成员文件构建完可删除 |
| `EXPORT_HDRS/libsa: no such file` | bootstrap pass 停在链接、未导出头文件 | 脚本已预建这些目录，保留该步骤 |
| `check-munch: set UNIXNU_UEFI` | 固件步骤缺环境变量 | `export UNIXNU_UEFI=$WORK/uefi` |
| 内核链接 `symbol(s) not found` | 选了阶段 2 组件却没有对应 archive | 见 `docs/04-troubleshooting.md`；脚本只构建阶段 1 组件集 |

## 7. 本地构建不做什么

- 不构建 userdata 镜像；继承的窗口几何对应完整约 226 GiB 分区，详见 `docs/04-troubleshooting.md`。
- 不发布 Release；产物留在 `out/`。
- 固件默认 DEBUG 构建，EDK II 断言会停住而不是继续。需要 release 卷时给
  `build package`/`build firmware` 加 `--target RELEASE`。

## 8. 安装 iOS 根卷窗口（C 阶段）

`fastboot flash userdata` 需要完整的约 226 GiB 分区镜像，所以根卷改为分三段写入。
内核的原生 UFS 根驱动读取 userdata 偏移 0 的 `SHNGROOT` 清单和其中的两个窗口：

| 偏移 | 内容 | 大小 |
| --- | --- | --- |
| 0 | `SHNGROOT` 清单（4096 字节）+ 零填充 | 1 MiB |
| 1 MiB | 展开后的 OS 磁盘镜像 | 6,077,580,800 |
| 5,798 MiB | SystemOS 镜像（`044-76034-038.dmg`） | 3,303,014,400 |

手机进入 TWRP（已开 adb）并连接 Mac 后：

```sh
chmod +x scripts/install-userdata-macos.sh
./scripts/install-userdata-macos.sh ~/munch-build
```

脚本会写清单、通过 `adb shell dd` 流式写入 OS 原始磁盘（总共只传约 8.7 GiB），
最后打印重启命令。开始前需要输入 `ERASE` 确认，因为 Android 数据会被替换。
