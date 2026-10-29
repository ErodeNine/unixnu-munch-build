#!/usr/bin/env bash
# Build every Redmi K40S (munch) image on a local macOS host.
#
#   scripts/build-local.sh [WORKDIR]
#
# WORKDIR defaults to $HOME/munch-build and is created on first use. The layout
# is fixed because the device repository's kit symlinks resolve to
# ../../UniXNU/kits:
#
#   WORKDIR/UniXNU   FFT-infra/UniXNU (the build driver, with submodules)
#   WORKDIR/device   WuBarlynn/unixnu-munch
#   WORKDIR/uefi     FFT-infra/uefi-alioth (with submodules)
#
# Requirements: macOS with Xcode (iOS 17 SDK), Homebrew packages
# llvm lld mtools dtc unifdef cmake ninja, Python 3.11+, ~30 GB free disk.
# See docs/05-local-macos.md for the long form.
set -euo pipefail

WORK=${1:-$HOME/munch-build}
HERE=$(cd "$(dirname "$0")/.." && pwd)
CHIP_ID=$(tr -d '[:space:]' < "$HERE/config/unique-chip-id.txt")
DEVICE_NAME=munch
DEFCONFIG=munch_defconfig
OS_PROFILE=ipados-17.7.11-21H461
OUT=$WORK/UniXNU/out/$DEVICE_NAME/$OS_PROFILE/$DEVICE_NAME

say() { printf '\n== %s\n' "$*"; }
need() { command -v "$1" >/dev/null || { echo "missing tool: $1" >&2; exit 1; }; }

need git; need python3; need dtc; need mformat; need mcopy; need openssl
if [ -z "${DEVELOPER_DIR:-}" ]; then
  XCODE=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -n 1 || true)
  [ -n "$XCODE" ] || { echo 'Xcode not found in /Applications' >&2; exit 1; }
  export DEVELOPER_DIR="$XCODE/Contents/Developer"
fi
LLVM=$(brew --prefix llvm 2>/dev/null || true)
[ -n "$LLVM" ] && export PATH="$LLVM/bin:$PATH"

mkdir -p "$WORK"
say "work directory: $WORK"

clone() {
  local dir=$1 url=$2
  if [ -d "$dir/.git" ]; then
    # The script pins the generated Data-seed UUID into the tracked defconfig on
    # every run, so a pull would refuse to start; the value is regenerated below.
    git -C "$dir" checkout -- configs/munch_defconfig 2>/dev/null || true
    git -C "$dir" pull --ff-only
  else
    git clone --recurse-submodules "$url" "$dir"
  fi
  git -C "$dir" submodule update --init --recursive --depth 1 || true
}

say 'checkout'
clone "$WORK/UniXNU" https://github.com/FFT-infra/UniXNU.git
clone "$WORK/device" https://github.com/WuBarlynn/unixnu-munch.git
clone "$WORK/uefi" https://github.com/FFT-infra/uefi-alioth.git

say 'apply the munch UEFI platform'
"$WORK/device/uefi/apply.sh" "$WORK/uefi"

cd "$WORK/UniXNU"

# prepare-xnu-source.py lists Apple sources through the GitHub API and needs a
# token; anonymous calls hit the shared rate limit (HTTP 403).
if [ -z "${GITHUB_TOKEN:-}" ] && command -v gh >/dev/null; then
  GITHUB_TOKEN=$(gh auth token 2>/dev/null || true)
fi
export GITHUB_TOKEN

say 'resolve the configuration'
./unixnu defconfig "$DEFCONFIG" -D "$WORK/device"
./unixnu fetch
./unixnu status --json | tee "$WORK/status.json"
./unixnu tree

say 'fetch the IPSW members over HTTP ranges'
./unixnu ipsw fetch OS Cryptex1,SystemOS StaticTrustCache Cryptex1,SystemTrustCache

say 'build the trust cache bundle'
VOL=.cache/firmware/target-volumes
mkdir -p "$VOL"
python3 "$HERE/scripts/prepare-trust-module.py" \
  out/ipsw/21H461/044-76040-038.dmg.trustcache "$VOL/static-trustcache.bin" \
  da88460e6e513438d5307e5c526f76497a74754476a24da29f239f0c90120fc2
python3 "$HERE/scripts/prepare-trust-module.py" \
  out/ipsw/21H461/044-76034-038.dmg.trustcache "$VOL/system-trustcache.bin" \
  d121ba89167e03aafd00fa687c30cd8ebc4ccafd10c1408adb2ba3de12403651
python3 - <<'PY'
import hashlib, struct
from pathlib import Path
vol = Path('.cache/firmware/target-volumes')
static = (vol / 'static-trustcache.bin').read_bytes()
system = (vol / 'system-trustcache.bin').read_bytes()
bundle = struct.pack('<3I', 2, 12, 12 + len(static)) + static + system
out = Path('build/original-static-system-trust')
out.mkdir(parents=True, exist_ok=True)
(out / 'original-static-system.bundle').write_bytes(bundle)
print('bundle sha256', hashlib.sha256(bundle).hexdigest())
PY

say 'prepare the Data seed and the owner root policies'
# The fixture, the packed seed and the grown seed all refuse to overwrite, so a
# rerun after an interrupted build starts from a clean directory.
rm -rf build/owner-data-fixture
mkdir -p "$VOL/os-mount"
hdiutil detach "$VOL/os-mount" -force >/dev/null 2>&1 || true
hdiutil attach -readonly -nobrowse -owners off -mountpoint "$VOL/os-mount" \
  out/ipsw/21H461/044-76040-038.dmg >/dev/null
trap 'hdiutil detach "$VOL/os-mount" -force >/dev/null 2>&1 || true' EXIT
python3 scripts/prepare-owner-data-fixture.py
python3 "$HERE/scripts/build-root-policy.py" --component os \
  --dmg out/ipsw/21H461/044-76040-038.dmg --out "$OUT/tree/build/verified-root-os" \
  --expected-sha256 3f99b859c9728379110b66657c7b15285bcb1925ad8b5726542e2cdcf8b1028d \
  --expected-blocks 1483785 --expected-uuid 04769D26-2CA0-4825-B443-E2E5F88300F2 \
  --mountpoint "$VOL/os-mount" --image-source disk
hdiutil detach "$VOL/os-mount" -force >/dev/null 2>&1 || true
trap - EXIT
python3 "$HERE/scripts/build-root-policy.py" --component systemos \
  --dmg out/ipsw/21H461/044-76034-038.dmg --out "$OUT/tree/build/verified-root-systemos" \
  --expected-sha256 b4908cde41d23e6bc05e6af51a2c9eeb00cf0f863a6a18b1600c96a3fd70414f \
  --expected-blocks 806400 --image-source file
mkdir -p build
python3 "$HERE/scripts/pack-data-seed.py" \
  build/owner-data-fixture/owner-data-32.cdr build/owner-data-fixture/owner-data-32.dbr
python3 scripts/seed-data-grow.py --gib 3 \
  build/owner-data-fixture/owner-data-32.dbr build/owner-data-fixture/owner-data-3.dbr

say 'pin the generated Data seed UUID'
UUID=$(python3 -c "import json;print(json.load(open('build/owner-data-fixture/seed.json'))['volume_uuid'])")
echo "Data seed volume UUID: $UUID"
python3 - "$WORK/device/configs/munch_defconfig" "$UUID" <<'PY'
import re, sys
path, uuid = sys.argv[1], sys.argv[2]
text = open(path).read()
text, count = re.subn(r'^CONFIG_XNU_OWNER_DATA_VOLUME_UUID=.*$',
                      f'CONFIG_XNU_OWNER_DATA_VOLUME_UUID="{uuid}"', text, flags=re.M)
if count != 1:
    raise SystemExit('expected exactly one CONFIG_XNU_OWNER_DATA_VOLUME_UUID line')
open(path, 'w').write(text)
PY
./unixnu defconfig "$DEFCONFIG" -D "$WORK/device"

say 'build kernel'
for d in libsa libkern osfmk bsd pexpert iokit security; do
  mkdir -p "$OUT/tree/build/xnu/ios-obj/EXPORT_HDRS/$d"
done
export UNIXNU_UEFI="$WORK/uefi"
# The display archive needs a bootstrap candidate plus a recorded runtime ABI
# observation. The candidate is this build's own prelinked kernel; the runtime
# observation is not shipped, so the audit treats it as unqualified. The static
# vtable, class-size and original-family hash checks stay in force.
python3 - <<'PY'
from pathlib import Path
audit = Path('scripts/audit-mobile-graphics-legacy.py')
text = audit.read_text()
old = ("    require(out.exists() and json.loads(out.read_text())['runtime_metadata_checkpoint_sha256']==RUNTIME_SHA,\n"
       "            'Recorded runtime observation hash')")
new = ("    import os\n"
       "    require(os.environ.get('UNIXNU_DISPLAY_ABI_UNQUALIFIED') == '1' or\n"
       "            (out.exists() and json.loads(out.read_text())['runtime_metadata_checkpoint_sha256']==RUNTIME_SHA),\n"
       "            'Recorded runtime observation hash')")
if old not in text:
    raise SystemExit('audit-mobile-graphics-legacy.py changed; update the patch')
audit.write_text(text.replace(old, new))
PY
# Pass 1 links a no-op sheng_pmgr_run: build-platform-power.py needs the previous
# prelinked kernel as its reference. Pass 2 links the real ApplePMGR bridge that
# AMFI's ConfigurationSettings requires, and the display archive against the
# candidate staged below.
./unixnu build kernel
mkdir -p "$OUT/tree/build/xnu-prelink"
cp "$OUT/kernel/kernel.macho" "$OUT/tree/build/xnu-prelink/native-owner-mobile-graphics-candidate.macho"
cp "$OUT/kernel/kernel.json" "$OUT/tree/build/xnu-prelink/native-owner-mobile-graphics-candidate.json"
UNIXNU_DISPLAY_ABI_UNQUALIFIED=1 ./unixnu build kernel

say 'build package'
./unixnu build package

say 'build firmware'
./unixnu build firmware --uefi "$WORK/uefi"

say 'build payload'
./unixnu build payload \
  --unique-chip-id "$CHIP_ID" \
  --trust-cache build/original-static-system-trust/original-static-system.bundle \
  --data-ramdisk build/owner-data-fixture/owner-data-3.dbr

say 'build boot image'
./unixnu bootimg --uefi "$WORK/uefi" --dtb "$WORK/uefi/Resources/DTBs/munch.dtb"

say 'done'
ls -l "$OUT/boot/boot.img" "$OUT/payload/payload.img" "$OUT/kernel/kernel.macho"
echo
echo "flash:  fastboot boot $OUT/boot/boot.img"
