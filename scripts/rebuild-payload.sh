#!/usr/bin/env bash
# Rebuild only the payload and the boot image, reusing the kernel and the firmware
# from the last full build.
#
#   scripts/rebuild-payload.sh [WORKDIR] [./unixnu payload arguments]
#
# The boot arguments live in the device repository's board.toml, so a change to
# them needs a new payload but no new kernel. A full build-local.sh run rebuilds
# both kernel passes because the generated Data-seed UUID changes the defconfig;
# this path is ready in about a minute. --kernel-arg NAME=VALUE overrides one
# argument for a single image without editing the repository.
#
# WORKDIR defaults to $HOME/munch-build and must already contain a full build.
set -euo pipefail

WORK=${1:-$HOME/munch-build}
[ $# -gt 0 ] && shift
HERE=$(cd "$(dirname "$0")/.." && pwd)
CHIP_ID=$(tr -d '[:space:]' < "$HERE/config/unique-chip-id.txt")
OUT=$WORK/UniXNU/out/munch/ipados-17.7.11-21H461/munch

need() { command -v "$1" >/dev/null || { echo "missing tool: $1" >&2; exit 1; }; }
need git; need python3; need mformat; need mcopy
LLVM=$(brew --prefix llvm 2>/dev/null || true)
[ -n "$LLVM" ] && export PATH="$LLVM/bin:$PATH"

for f in "$OUT/kernel/kernel.macho" \
         "$WORK/UniXNU/build/original-static-system-trust/original-static-system.bundle" \
         "$WORK/UniXNU/build/owner-data-fixture/owner-data-3.dbr"; do
  [ -f "$f" ] || { echo "missing $f; run scripts/build-local.sh first" >&2; exit 1; }
done

# The arguments come from the device repository. The defconfig carries the Data
# seed UUID pinned by the last full build, so a pull would refuse to start.
git -C "$WORK/device" checkout -- configs/munch_defconfig 2>/dev/null || true
git -C "$WORK/device" pull --ff-only

cd "$WORK/UniXNU"
export UNIXNU_UEFI="$WORK/uefi"
./unixnu build payload \
  --unique-chip-id "$CHIP_ID" \
  --trust-cache build/original-static-system-trust/original-static-system.bundle \
  --data-ramdisk build/owner-data-fixture/owner-data-3.dbr \
  --skip-setup "$@"
./unixnu bootimg --uefi "$WORK/uefi" --dtb "$WORK/uefi/Resources/DTBs/munch.dtb"

echo
echo "flash:  fastboot boot $OUT/boot/boot.img"
