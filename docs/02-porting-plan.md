# K40S porting plan (mapped to the eight official UniXNU steps)

English | [简体中文](02-porting-plan.zh-CN.md)

The official procedure is https://unixnu.com/porting/steps. Each step below lists the official requirement, the file in this repository that satisfies it, and the current verification state.

## Step 1: collect the device inputs

| Input | Value | Source |
| --- | --- | --- |
| Codename / model | `munch` / `22021211RC` (K40S), `22021211RG` (POCO F4) | Xiaomi model-number scheme, LineageOS wiki |
| SoC | SM8250-AC (kona), `qcom,msm-id = <0x164 0x20001>` | vendor device tree |
| CPU | 4×A55 (cpu0-3) + 4×A77 (cpu4-7), MPIDR 0x000–0x700 | `kona.dtsi` |
| Memory | base `0x80000000`; splash `0x9c000000+0x2300000` | `kona.dtsi` |
| Storage | UFS `0x1d84000`, PHY `0x1d87000` | `kona.dtsi` |
| Touch | FocalTech, `qupv3_se4_spi`, 6 MHz, GPIO33 reset / GPIO39 IRQ | `munch-sm8250.dtsi` |
| Wireless | QCA6390 | `xiaomi-sm8250-common.dtsi` |
| Firmware | Mu-Silicium `SOC_TYPE=2` (SM8250-AC) | `uefi-alioth` |

Recorded in `docs/CHANGES-from-alioth.md`.

## Step 2: choose shared support

| Layer | Choice | Note |
| --- | --- | --- |
| ARM64 profile | `UniXNU/profiles/arch/arm64` | official common patches |
| SoC | `FFT-infra/UniXNU-sm8250-common@a6e7e36` | explicitly covers SM8250-AC; SMP patches and the A650 GMU kit |
| OS | `ipados-17.7.11-21H461` | the only complete profile in the tree; ADT identity overridden to iPhone10,3 |
| Device | this repository | board, DTS, defconfig, archives |
| Firmware | `FFT-infra/uefi-alioth` + the `uefi/` overlay | aliothPkg is already SM8250-AC |

## Step 3: create the device repository

The official layout is present:

```
board.toml                     # schema_version=2, munch identity
feeds.toml                     # sm8250 and ShengUfs pinned
configs/munch_defconfig
dts/munch.dts
patches/xnu/series
package/                       # board services and probes
kits/munch-touch/              # FocalTech touch
proprietary-files.txt
porting.toml
uefi/                          # added here: Mu-Silicium platform overlay
unixnu.lock
```

`uefi/` is not part of the official layout. It keeps the munch firmware files next to the board description so two repositories are enough; it can be promoted to a standalone `uefi-munch` repository later.

## Step 4: resolve and inspect the build

```sh
./unixnu defconfig munch_defconfig -D ../unixnu-munch
./unixnu fetch
./unixnu status --json
./unixnu tree
```

Expected: `status` reports `soc=SM8250`, `soc_source=sm8250`, `os_profile=ipados-17.7.11-21H461`, and the device package appears as `tree/kits/munch/`.

## Step 5: hardware description and firmware

| Output | Source | Note |
| --- | --- | --- |
| XNU ADT | `dts/munch.dts` → `make-adt.py` | the payload step writes `kernel.macho.adt` |
| firmware DTB | `uefi/Resources/DTBs/munch.dts` → `dtc` | input to `bootimg --dtb`; carries `cont_splash_region` |
| UEFI FD | `uefi/munchPkg/munch.dsc/.fdf` | already includes UniXNU, UniXNUDxe, UniXNURamDiskDxe, DarwinBoot, FAT/DiskIo |

Key lines in `munch.dsc`:

```ini
SOC_TYPE = 2                       # SM8250-AC
USE_CUSTOM_DISPLAY_DRIVER = 0      # simple framebuffer, no panel XML
gUniXNUPkgTokenSpaceGuid.PcdUniXNUDebugLevel|0x80000000
PcdCPUCoresStackBase|0x9FF90000
```

## Step 6: adapt drivers in dependency order

| Subsystem | Implementation here | State |
| --- | --- | --- |
| platform and memory | `ArmDTPlatform` + `ArmCpu` + SM8250 DTSI | inherited from alioth; addresses checked |
| UFS | `ShengUfs` (`NativeUfs-alioth`) | inherited; stream `0x0e0/0x4e0` |
| display | `GopFramebuffer` / `build-gop-legacy-display.py` | inherited; 1080×2400 |
| touch | `kits/munch-touch` + `ShengHidInput` | inherited; GPIO to be measured |
| GPU | A650 code present, disabled for the first image | probe only |
| Wi-Fi/audio/power | — | not implemented |

## Step 7: build and start

```sh
./unixnu build kernel
./unixnu build package
./unixnu build firmware --uefi ../uefi-alioth
./unixnu build payload --unique-chip-id <hex> --trust-cache <bundle> --data-ramdisk <seed>
./unixnu bootimg --uefi ../uefi-alioth --dtb ../uefi-alioth/Resources/DTBs/munch.dtb
```

Outputs: `out/munch/ipados-17.7.11-21H461/munch_defconfig/{kernel,package,firmware,payload,boot}/`.
Boot commands and checkpoints are in `03-real-device-test.md`.

## Step 8: complete and publish

- `.github/workflows/porting-record.yml` validates `porting.toml` on push.
- `porting.toml`'s summary now describes munch; each area's evidence still comes from alioth and must be replaced after hardware tests.
- Publishing to the official device catalog needs the `unixnu` topic and a pull request to UniXNU; this port does not do that automatically.

## Relationship to the mature ports

| Reference | Role |
| --- | --- |
| Xiaomi Pad 6S Pro (sheng, SM8550) | the official, most complete port: UEFI/DarwinBoot/display/touch/GPU/Wi-Fi all implemented. The archive layout, UEFI module set and payload/ADT conventions come from it |
| Redmi K40 (alioth, SM8250) | the direct same-SoC predecessor: kernel configuration, UFS root, GOP display, FocalTech touch, USB debug console |
| Mi 10S (thyme, SM8250-AC) | a community port on the same SoC variant, confirming the -AC support path |
