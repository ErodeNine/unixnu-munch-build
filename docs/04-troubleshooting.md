# Known limits and troubleshooting

English | [简体中文](04-troubleshooting.zh-CN.md)

## 1. The ceiling inherited from alioth

The archive chain, kernel configuration and board services come from `UniXNU-alioth`. That port's record (revision 2026-10-28) says:

| Area | alioth state |
| --- | --- |
| CPU / interrupts | implemented |
| storage and root | device-verified (UFS reads verified; root protected by the owner policy) |
| display | implemented (GOP; lock screen renders) |
| input | implemented (FocalTech frames read; HID publication still being verified) |
| GPU / network / audio / power | planned |

A realistic K40S expectation is therefore: **UEFI → menu → DarwinBoot → XNU console → UFS root → possibly the lock screen**. GPU/Metal, Wi-Fi and audio are outside this round.

## 2. Two macOS-only steps

| Step | Reason | Current approach |
| --- | --- | --- |
| `prepare-owner-data-fixture.py` | creates an APFS container with `hdiutil` | GitHub Actions `macos-26` |
| `seed-data-grow.py` | `diskutil apfs resizeContainer` | same |
| `build-original-system-trust.py` | needs the full IPSW and macOS extraction | same |

Linux can run kernel (after `scripts/linux/setup-toolchain.py`), package, firmware, boot image and userdata.

## 3. Disk

- IPSW ≈ 7 GB; OS/SystemOS dmg ≈ 4 GB each; userdata image ≈ 8 GB.
- A hosted `macos-26` runner has about 14 GB free, **not enough for everything**. The pipeline skips userdata by default.
- For userdata use a self-hosted runner (`runs-on: [self-hosted, macOS]`) or a larger runner.

## 4. Vendor firmware

- `Binaries/munch` is currently a copy of `Binaries/alioth` (the same SM8250 reference set).
- If the UEFI stage is blank or the buttons misbehave, extract the K40S's own DXE set: `03-real-device-test.md`, D2.
- `Resources/DTBs/munch.dtb` is the decompiled alioth tree; the best input is the stock DT from the phone's boot partition.

## 5. Common build errors

| Error | Cause | Fix |
| --- | --- | --- |
| `board.example = true` | template repository not completed | this repository has no such field |
| `defconfig: unknown fragment` | `config_fragments` names a missing file | check `soc:configs/sm8250.config` |
| `fetch: repository not found` | a dead `feeds.toml` URL | this repository already points `NativeUfs` back at `NativeUfs-alioth` |
| `check-munch: Binaries/munch inputs are missing` | `uefi/apply.sh` not run | apply the overlay first |
| `munch.dtb is missing` | device tree not compiled | `apply.sh` runs `dtc` |
| `hdiutil: attach failed` | dmg not extracted or busy | re-run `extract-target-volume.py OS` |
| `Require the unchanged supplied original OS mount` | the OS volume is not from the target IPSW | use 17.7.11 / 21H461 |

## 6. Debug channels

| Channel | Available from | How to read |
| --- | --- | --- |
| screen (GOP) | UEFI onwards | photograph |
| USB CDC-ACM | after the kernel starts | `/dev/ttyACM0` 115200 8N1 |
| QR log export | not integrated on this platform | — |
| UART | not exposed on the K40S | — |

## 7. Compliance

- The outputs contain Apple IPSW-derived material; keep the repository private.
- Do not redistribute `userdata-root.img`, `kernel.macho` or `payload.img`.
- This project does not bypass Apple's activation or signing services; it is system-porting research for hardware you own.

## GUI boundary (measured 2026-10-29)

The image with the display and touch archives reaches userspace on hardware:

- `/private/var`, `launchd`, `keybagd`, `usermanagerd`, `datamigrator` all exit 0;
- the display backend reports `DISPLAY stage=10 PM=4 calls=4 callbacks=1` and the panel
  shows the diagnostic colour bands, so `IOMobileFramebufferLegacy` is registered and
  has a client;
- an earlier boot respawned `SpringBoard` into the FrontBoard assertion
  `failed to find the main CADisplay` (`sig5 ns=2 code=5`);
- with the Data seed in place the GUI comes up: Setup Assistant renders its language
  picker, so backboardd, WindowServer and the render server are running.

Remaining issues at this point are the panel identity/scale (the status bar is not drawn:
1080x2400 against the iPhone10,3 1125x2436@3x identity) and touch input
(`contacts=0`, `hid=0`, `hres=1`). Pass `--skip-setup` to the payload step to boot past
Setup Assistant once the identity is settled.

