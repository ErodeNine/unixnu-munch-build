# K40S hardware test manual (step by step)

English | [简体中文](03-real-device-test.zh-CN.md)

> Applies to: Redmi K40S / POCO F4 (`munch`), SM8250-AC.
> Prerequisite: **bootloader unlocked**. Apply through Xiaomi's unlock tool first (the waiting period is usually 168 hours).
> Risk: unlocking wipes data; flashing `userdata` wipes it again. **Stage A uses `fastboot boot` and writes nothing**, so it can always be rolled back by holding power.

Three stages, in order. Do not skip.

| Stage | Action | Destructive | Goal |
| --- | --- | --- | --- |
| A | `fastboot boot boot.img` | no | UEFI menu, DarwinBoot, XNU console |
| B | `fastboot flash boot_a/boot_b` | recoverable | UniXNU survives a reboot |
| C | `fastboot flash userdata` | **wipes data** | iOS Data volume mounts, userland starts |

> Stage 1 image (v0.9 and later): no display backend and no touch driver. The panel shows
> the kernel frame-buffer text that `build-boot-progress.py` paints (boot stages and panics),
> the UEFI menu still takes volume/power or a USB keyboard, and the kernel log arrives on
> the USB CDC-ACM port. A lock screen, wallpaper or touch input is stage 2.

---

## 0. Checklist

- Host with `platform-tools` (Windows/Linux/macOS).
- A good USB-C cable.
- Battery ≥ 50%.
- The matching **official fastboot ROM** for `munch` (`munch_images_*.tgz`) for rollback.
- A host that can capture serial logs (USB re-enumerates during boot).

```sh
adb version
fastboot --version
```

---

## 1. Identify and back up

### 1.1 Enter fastboot

Power off, then hold **Volume Down + Power** until the fastboot screen appears.

```sh
fastboot devices
fastboot getvar product          # expect: munch
fastboot getvar current-slot     # a or b
fastboot getvar partition-size:boot_a
fastboot getvar partition-size:boot_b
fastboot getvar partition-size:userdata
fastboot getvar unlocked         # expect: yes
```

Record:

| Item | Value | Use |
| --- | --- | --- |
| product |  | must be `munch`, otherwise stop |
| current-slot |  | which slot stage B flashes |
| boot_a bytes |  | must be ≥ 192 MiB |
| boot_b bytes |  | same |
| userdata bytes |  | LBA calculation, see 1.3 |

### 1.2 Back up boot / dtbo (strongly recommended)

With root (Magisk/KernelSU) on Android:

```sh
adb shell su -c 'dd if=/dev/block/by-name/boot_a of=/sdcard/boot_a.img'
adb shell su -c 'dd if=/dev/block/by-name/boot_b of=/sdcard/boot_b.img'
adb shell su -c 'dd if=/dev/block/by-name/dtbo of=/sdcard/dtbo.img'
adb pull /sdcard/boot_a.img
adb pull /sdcard/boot_b.img
adb pull /sdcard/dtbo.img
```

Without root, extract `boot.img` from the official fastboot ROM and keep that as the rollback image.

### 1.3 Compute the userdata LBAs

`board.toml` `[userdata] first_lba/last_lba` must match the device GPT. From `fastboot getvar partition-size:userdata`:

```
first_lba = the partition's first sector (read the GPT, below)
last_lba  = floor(bytes / 4096) + first_lba - 1
```

Read the GPT (root):

```sh
adb shell su -c 'sgdisk -p /dev/block/sda' | grep userdata
# or
adb shell su -c 'parted /dev/block/sda unit s print' | grep userdata
```

Write the result into `unixnu-munch/board.toml` and rebuild the payload and boot image. Otherwise stage C writes to the wrong place.

### 1.4 Extract the stock DT (to replace the alioth-derived firmware DTB)

```sh
magiskboot unpack boot_a.img          # produces kernel / ramdisk / dtb
dtc -I dtb -O dts dtb -o munch-stock.dts
```

Compare with `uefi/Resources/DTBs/munch.dts`. Check `qcom,board-id` (K40S is `<0x32 0x00>`), `/memory` and `/reserved-memory/cont_splash_region`. Replace the file and rebuild when they differ. This is the single most useful step before P0.

---

## Stage A: non-destructive boot

```sh
fastboot boot path/to/boot.img
```

`fastboot boot` loads the image into RAM only. On failure the phone reboots back into Android.

### A1 expected observations, in order

| # | Checkpoint | Observation | If it fails |
| --- | --- | --- | --- |
| A1 | UEFI init | the Xiaomi logo or a black screen for a few seconds, then the UniXNU menu | no menu at all → 4.1 |
| A2 | menu | a `Boot` entry with a 3 s countdown | menu but no entry → 4.2 |
| A3 | DarwinBoot | UniXNU/DarwinBoot text or colour bands | hang → 4.3 |
| A4 | XNU console | kernel log lines, `Darwin Kernel Version` | panic → 4.4 |
| A5 | root volume | UFS/IOMedia/root lines | 4.5 |

### A2 controls

- Volume up/down moves, power confirms (`ButtonsDxe` maps power to ENTER).
- If the buttons do nothing, plug in a **USB keyboard** and use arrows + Enter (UsbKbDxe is in the firmware).

### A3 capture logs

After the kernel starts, USB re-enumerates as a CDC-ACM port (VID:PID `1209:316d`, `QcomXnuUsbDebug`):

- Linux: find `/dev/ttyACM0`, then
  `picocom -b 115200 /dev/ttyACM0 | tee munch-boot-$(date +%s).log`
- Windows: note the COM port in Device Manager, use PuTTY (Serial, 115200 8N1) and log to file.
- macOS: `screen /dev/tty.usbmodem* 115200`, `Ctrl-A` `H`.

Expected, in order:

```
UNIXNU: ...            # firmware/menu
DARWINBOOT: ...        # handoff
Darwin Kernel Version  # kernel
TOUCH start=1          # touch probe (with native-touch=1)
```

Archive the log and a photo of the screen in the table at section 5.

---

## Stage B: write the boot partition (optional)

Only after three consecutive successful stage-A runs reaching A4.

```sh
fastboot flash boot_a boot.img
# if current-slot=b and you want to boot from b:
fastboot flash boot_b boot.img
fastboot --set-active=b
```

**Rollback**:

```sh
fastboot flash boot_a stock-boot.img
fastboot flash boot_b stock-boot.img
```

Or `fastboot reboot` and restore fully with the official ROM's `flash_all.bat`.

---

## Stage C: install userdata (destructive, last)

Only after stage B is stable and the LBAs from 1.3 are verified.

```sh
fastboot flash userdata userdata-root.img
```

This takes a while (several GiB). After reboot, watch the log for:

- the APFS container/volume;
- `launchd` starting;
- the Data volume mount result.

Failure branches: 4.5 / 4.6.

---

## 4. Failure branches

### 4.1 A1: black screen, no menu

1. Confirm `fastboot getvar product` is `munch`.
2. Confirm you are booting `boot.img`, not `SILICIUM_UEFI.fd`.
3. Compare `Binaries/munch` with `Binaries/alioth`; if the screen stays black, the vendor DXE set is incompatible and must be extracted (D2).
4. Check `boot.json` in the release: `ramdisk_bytes` must be nonzero.

### 4.2 Menu appears but has no Boot entry

The UEFI cannot find the payload FAT volume:

- `boot.json` `ramdisk_bytes` should be around 176 MiB;
- the FDF must contain `UniXNURamDiskDxe`, `DiskIoDxe` and `Fat`;
- the serial log should contain `UNIXNURAMDISK: initrd block device`.

### 4.3 Hang in DarwinBoot

- almost always a mismatch between `kernel.macho.adt` and `kernel.macho`, or a missing `unixnu.toml` entry;
- rebuild the payload and then the boot image in one sequence.

### 4.4 Kernel panic

Photograph the panic screen, or read the first `panic(cpu ...)` line from the serial log.

| Panic | Meaning | Action |
| --- | --- | --- |
| `rootvp not authenticated after mounting` | owner root trust chain not active | confirm `CONFIG_XNU_OWNER_ROOT_TRUST=y` and the trust cache |
| `offline scratch Data mount failed: 2` | Data volume not published through RamBlock | confirm `CONFIG_XNU_NATIVE_RAM_BLOCK=y` and that the payload carries the Data seed |
| `Invalid kernel stack pointer` | SMP topology patches missing | confirm `native-smp-secondary.patch` and `native-smp-type-clusters.patch` are in the SoC series |

### 4.5 UFS / root volume failure

- DTS `&ufs` and `&ufsphy` must be `okay`;
- boot arguments `native-ufs-stream=0xe0`, `native-ufs-stream2=0x4e0`, `native-ufs-root=1`;
- if the UFS link does not come up, boot Android once to confirm the hardware.

### 4.6 Touch does nothing

`kits/munch-touch` records reset GPIO 101 while the munch vendor DTS uses GPIO 33. One of them does not match your batch: check `TOUCH start=1` and the `contacts=` counter in the serial log, then adjust `FocalTouchBoard.h`.

---

## D2 (advanced): extract the K40S's own vendor DXE

> Only needed when A1 fails or charging/buttons misbehave.

1. Extract `xbl.elf` from the official fastboot ROM (or `dd if=/dev/block/by-name/xbl` with root).
2. Open it in [UEFITool](https://github.com/LongSoft/UEFITool) and locate the DXE driver volumes.
3. Mirror the `Binaries/alioth/QcomPkg/Drivers/<Name>/` layout under `Binaries/munch/...` with the same-named `.efi` and `.depex`. The `.inf` wrappers can be reused (same `FILE_GUID` and `BASE_NAME`).
4. `uefi/apply.sh` does not overwrite an existing `Binaries/munch`; rebuild the firmware afterwards.

---

## 5. Record sheet (copy per run)

| Item | Content |
| --- | --- |
| Date / build number |  |
| Model / codename |  |
| RAM | 6 / 8 / 12 GiB |
| current-slot |  |
| boot.img md5 |  |
| Checkpoint reached | A1 / A2 / A3 / A4 / A5 |
| Key log lines |  |
| First panic line |  |
| Screen photo |  |
| Next action |  |

---

## 6. One-shot environment dump (optional)

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
