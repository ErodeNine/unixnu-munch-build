# Redmi K40S (munch) UniXNU feasibility assessment

English | [简体中文](01-feasibility.zh-CN.md)

Date: 2026-10-28

**Conclusion: technically feasible, and one of the most favourable porting candidates available.** A same-SoC reference port (alioth) already reaches the kernel, display and touch stages, and the K40S matches it item by item on every peripheral the boot chain needs. Reaching a full iOS desktop still depends on upstream progress and on two inputs that require macOS, so no single-build success is promised.

## 1. Evidence

| Source | Use | Finding |
| --- | --- | --- |
| https://unixnu.com/ (whole site, fetched through the local SOCKS5 proxy on 20122) | architecture, eight-step porting method, build commands, device-repository specification | six-layer boot stack; `./unixnu defconfig/fetch/tree/build/bootimg` is the only build entry point |
| https://unixnu.com/devices/munch | whether a munch port exists | **HTTP 404** — the K40S is not in the official device list |
| `FFT-infra/UniXNU-sm8250-common@a6e7e36` | shared SoC support | `soc.toml` covers **SM8250 / SM8250-AC (kona)**; GICv3, timer, UFS, QUPv3, A650 GMU kit, SMP patches |
| `FFT-infra/UniXNU-alioth@c567d24` | same-generation reference device | full archive chain, UFS root, GOP display, FocalTech SE4 touch, USB debug console |
| `FFT-infra/uefi-alioth@d2710c6` | Mu-Silicium base firmware | `aliothPkg` sets `SOC_TYPE = 2` (SM8250-AC) and `USE_CUSTOM_DISPLAY_DRIVER = 0` (simple framebuffer, no panel init) |
| LineageOS `android_kernel_xiaomi_sm8250`: `kona.dtsi`, `munch-sm8250.dtsi` | the K40S's real hardware description | splash `0x9c000000+0x2300000`; UFS `0x1d84000`; touch on SE4 at 6 MHz, reset GPIO 33, IRQ GPIO 39; QCA6390 |

## 2. Hardware comparison (K40S vs alioth)

| Item | K40S (munch) | Redmi K40 (alioth) | Reusable |
| --- | --- | --- | --- |
| SoC | SM8250-AC (kona) | SM8250 / -AC | yes — same SoC repository |
| CPU | 4×A55 + 4×A77 | same | yes |
| RAM base | `0x80000000`, 6/8/12 GiB | same | yes |
| Display | 1080×2400 AMOLED 120 Hz | 1080×2400 AMOLED 120 Hz | yes — GOP simple framebuffer |
| splash reservation | `0x9c000000` + `0x2300000` | same | yes — byte-identical |
| Storage | UFS 3.1 `0x1d84000` / PHY `0x1d87000` | same | yes — same driver, stream `0x0e0/0x4e0` |
| Touch | FocalTech on GENI SE4, 6 MHz, GPIO33/39 | same | yes — same path (reset pin to be confirmed on hardware) |
| Wi-Fi/BT | QCA6390 | QCA6390 | driver not implemented (does not block kernel boot) |
| Charging | 67 W (BQ2597x/QC30 family) | 33 W | not shared; later work |
| Panel IC | munch-specific AMOLED | alioth-specific | only affects a custom display driver; the simple framebuffer bypasses it |

Only charging, the panel IC and the cameras differ in ways that matter. Every peripheral on the boot path is structurally identical.

## 3. Stage-by-stage probability

| Stage | Depends on | Outlook | Basis |
| --- | --- | --- | --- |
| P0 UEFI firmware boots, menu appears | munchPkg + vendor DXE | **high** | aliothPkg is already SM8250-AC; its memory map matches the K40S `kona.dtsi` exactly |
| P1 DarwinBoot handoff, XNU reaches the kernel | kernel.macho + ADT + payload | **high** | alioth has measured this; the K40S uses the same configuration |
| P2 UFS root volume publication | ShengUfs + verified root | **medium-high** | device-verified on alioth; the UFS host is the same |
| P3 display and touch | GOP + FocalTech | **medium** | implemented on alioth; the K40S panel and touch batch are different and must be measured |
| P4 to SpringBoard/desktop | Data volume, trust cache, GPU | **medium-low** | alioth is still working through the Data volume and GPU; the K40S inherits that ceiling |
| P5 GPU/Metal, Wi-Fi, audio, power | A650, QCA6390, DSP | **low for this round** | upstream components are unfinished; out of scope |

## 4. Known blockers

1. **Vendor UEFI DXE binaries.** No K40S dump exists yet. The build currently uses `Binaries/alioth` (the same SM8250 reference set). Extraction procedure: `03-real-device-test.md`, step D2.
2. **Firmware DTB.** `Resources/DTBs/munch.dtb` is the decompiled alioth tree with `model` and `qcom,board-id=0x32` rewritten. The correct input is the K40S's own `dtbo`/`boot` device tree.
3. **userdata LBAs.** `board.toml [userdata]` still carries alioth's sector range. Verify against `fastboot getvar partition-size:userdata` and the device GPT before any flash.
4. **Data volume seed.** The official script needs macOS `hdiutil` to create the APFS container; this port generates it on a GitHub Actions macOS runner.
5. **Upstream completeness.** alioth still lists GPU, network, audio and power as planned. Even with everything working, the first K40S milestone is *UEFI menu → kernel console → root volume*, not a full iOS desktop.

## 5. Verdict

- **Feasible**, with lower risk than a from-scratch port because the SoC and every boot-critical peripheral have a same-generation reference.
- **This delivery**: the complete device repository (`unixnu-munch`), the UEFI platform overlay (`uefi/`), the build pipeline and all documents.
- **Hardware plan**: verify P0–P2 first, then work through P3–P4. A single successful "iOS fully booted" run is not the acceptance criterion for the first test.
