#!/usr/bin/env bash
# Install the iOS root windows into the phone's userdata partition from macOS.
#
#   scripts/install-userdata-macos.sh [WORKDIR]
#
# The kernel's native UFS root driver reads a SHNGROOT manifest at offset 0 of
# userdata, then two windows: the OS disk image at 1 MiB and the SystemOS disk
# image after it. Writing those three pieces is enough; the full partition image
# is ~226 GiB and is never transferred.
#
# Requirements: macOS with hdiutil, adb (brew install android-platform-tools),
# python3, the phone booted into TWRP with adb enabled, and a UniXNU tree whose
# out/ipsw/21H461/ already holds 044-76040-038.dmg and 044-76034-038.dmg
# (scripts/build-local.sh leaves them there). The phone's userdata is erased.
set -euo pipefail

WORK=${1:-$HOME/munch-build}
IPSW_DIR=$WORK/UniXNU/out/ipsw/21H461
OS_DMG=$IPSW_DIR/044-76040-038.dmg
SYS_DMG=$IPSW_DIR/044-76034-038.dmg
OS_SHA=e5634d04a8ac35f024845f583394e0a35deb26a04cb0c00286a8674e25a9a4f2
SYS_SHA=b4908cde41d23e6bc05e6af51a2c9eeb00cf0f863a6a18b1600c96a3fd70414f
BY_NAME=/dev/block/by-name/userdata

say() { printf '\n== %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

command -v adb >/dev/null || die 'adb missing (brew install android-platform-tools)'
command -v hdiutil >/dev/null || die 'hdiutil missing'
[ -f "$OS_DMG" ] || die "$OS_DMG missing; run scripts/build-local.sh first"
[ -f "$SYS_DMG" ] || die "$SYS_DMG missing; run scripts/build-local.sh first"

adb get-state >/dev/null 2>&1 || die 'no adb device; boot the phone into TWRP and enable adb'

say 'layout'
LAYOUT=$(python3 - "$OS_DMG" "$SYS_DMG" "$OS_SHA" "$SYS_SHA" <<'PY'
import hashlib, os, struct, sys
from pathlib import Path
MIB = 1 << 20
os_dmg, sys_dmg, os_sha, sys_sha = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4]
# The OS window is the expanded disk; its size is the UDIF trailer's total.
import plistlib, subprocess
try:
    info = plistlib.loads(subprocess.check_output(['hdiutil','imageinfo','-plist',str(os_dmg)]))
    os_size = int(info.get('Total Bytes') or info.get('Size Information',{}).get('Total Bytes') or 0)
except Exception:
    os_size = 0
if not os_size:
    os_size = os.stat(os_dmg).st_size
sys_size = os.stat(sys_dmg).st_size
os_off = MIB
sys_off = (os_off + os_size + MIB - 1) // MIB * MIB
end = (sys_off + sys_size + MIB - 1) // MIB * MIB
header = bytearray(4096)
header[0:8] = b'SHNGROOT'
struct.pack_into('<IIQ', header, 8, 1, 2, end)
struct.pack_into('<32sQQII32s40s', header, 24, b'OS', os_off, os_size, 512, 1, bytes.fromhex(os_sha), bytes(40))
struct.pack_into('<32sQQII32s40s', header, 152, b'SystemOS', sys_off, sys_size, 512, 1, bytes.fromhex(sys_sha), bytes(40))
header[4064:4096] = hashlib.sha256(bytes(header[:4064])).digest()
Path('userdata-manifest.bin').write_bytes(bytes(header) + bytes(MIB - 4096))
print(f'{os_off} {os_size} {sys_off} {sys_size} {end}')
print(f'manifest sha256 {hashlib.sha256(bytes(header)).hexdigest()}')
PY
)
printf '%s\n' "$LAYOUT"
OS_OFF=$(printf '%s\n' "$LAYOUT" | sed -n 1p | cut -d' ' -f1)
OS_SIZE=$(printf '%s\n' "$LAYOUT" | sed -n 1p | cut -d' ' -f2)
SYS_OFF=$(printf '%s\n' "$LAYOUT" | sed -n 1p | cut -d' ' -f3)
SYS_SIZE=$(printf '%s\n' "$LAYOUT" | sed -n 1p | cut -d' ' -f4)
END=$(printf '%s\n' "$LAYOUT" | sed -n 1p | cut -d' ' -f5)
echo "OS       offset $OS_OFF size $OS_SIZE"
echo "SystemOS offset $SYS_OFF size $SYS_SIZE"
echo "image end    $END"

say 'phone storage'
adb shell "blockdev --getsize64 $BY_NAME 2>/dev/null || true"
echo "need $END bytes"

cat <<'EOF'

This erases the phone's userdata partition (Android data is already replaced by
the iOS windows). Type ERASE to continue:
EOF
read -r answer
[ "$answer" = ERASE ] || die 'aborted'

say 'unmount data on the phone'
adb shell 'umount -l /data /sdcard 2>/dev/null || true'

say 'write the SHNGROOT manifest (1 MiB at offset 0)'
adb shell "dd of=$BY_NAME bs=1048576 seek=0 conv=notrunc" < userdata-manifest.bin

say 'attach the OS image and stream the expanded disk'
ATTACH=$(hdiutil attach -nomount -readonly -noverify -noautofsck "$OS_DMG")
DISK=$(printf '%s\n' "$ATTACH" | awk '/^\/dev\/disk/ && $1 !~ /s[0-9]+$/ {print $1; exit}')
[ -n "$DISK" ] || die 'could not find the whole disk for the OS image'
RAW=/dev/r$(basename "$DISK")
echo "OS raw device: $RAW"
trap 'hdiutil detach "$DISK" -force >/dev/null 2>&1 || true' EXIT
dd if="$RAW" bs=1m | adb shell "dd of=$BY_NAME bs=1048576 seek=1 conv=notrunc"
hdiutil detach "$DISK" -force >/dev/null 2>&1 || true
trap - EXIT

say 'write the SystemOS image'
SYS_SEEK=$((SYS_OFF / 1048576))
adb shell "dd of=$BY_NAME bs=1048576 seek=$SYS_SEEK conv=notrunc" < "$SYS_DMG"

say 'verify the manifest block'
adb shell "dd if=$BY_NAME bs=4096 count=1 2>/dev/null" | head -c 8 | od -An -c

cat <<EOF

done. Reboot to the bootloader and start the image:

  adb reboot bootloader
  fastboot boot $WORK/UniXNU/out/munch/ipados-17.7.11-21H461/munch/boot/boot.img

EOF
