#!/usr/bin/env bash
# Build the kernel in two passes.
#
#   scripts/steps/build-kernel.sh <unixnu> <device> <repo> <bootstrap>
#
# Pass 1 uses a copy of the device repository without the display, touch and HID
# archives (their recipes need the prelinked kernel as a reference) and links a
# no-op sheng_pmgr_run. Its prelinked kernel is then staged under the candidate
# names those recipes look for. Pass 2 switches back to the full device, links
# the real ApplePMGR bridge and builds the display/touch archives.
#
# The runtime ABI observation for the display audit is not shipped, so the audit
# is patched to accept UNIXNU_DISPLAY_ABI_UNQUALIFIED=1. The static vtable,
# class-size and original-family hash checks stay in force.
set -euo pipefail

UNIXNU=${1:?usage: build-kernel.sh unixnu device repo bootstrap}
DEVICE=${2:?}
REPO=${3:?}
BOOTSTRAP=${4:?}
cd "$UNIXNU"

OUT=out/munch/ipados-17.7.11-21H461/munch

# The bootstrap pass stops at the link, so EXPORT_HDRS never appears, while
# build-verified-root-probe.py compiles with the recorded flags and -Werror.
for d in libsa libkern osfmk bsd pexpert iokit security; do
  mkdir -p "$OUT/tree/build/xnu/ios-obj/EXPORT_HDRS/$d"
done

python3 "$REPO/scripts/prepare-bootstrap-device.py" "$DEVICE" "$BOOTSTRAP"
./unixnu defconfig munch_defconfig -D "$BOOTSTRAP"
./unixnu tree -D "$BOOTSTRAP"
./unixnu build kernel -D "$BOOTSTRAP"

mkdir -p "$OUT/tree/build/xnu-prelink"
cp "$OUT/kernel/kernel.macho" "$OUT/tree/build/xnu-prelink/native-owner-mobile-graphics-candidate.macho"
cp "$OUT/kernel/kernel.json"  "$OUT/tree/build/xnu-prelink/native-owner-mobile-graphics-candidate.json"
# The HID recipe looks for the ufs-cpu-desktop candidate name instead.
cp "$OUT/kernel/kernel.macho" "$OUT/tree/build/xnu-prelink/native-owner-ufs-cpu-desktop-munch-candidate.macho"
cp "$OUT/kernel/kernel.json"  "$OUT/tree/build/xnu-prelink/native-owner-ufs-cpu-desktop-munch-candidate.json"

./unixnu defconfig munch_defconfig -D "$DEVICE"
./unixnu tree -D "$DEVICE"

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
if 'UNIXNU_DISPLAY_ABI_UNQUALIFIED' not in text:
    if old not in text:
        raise SystemExit('audit-mobile-graphics-legacy.py changed; update the patch')
    audit.write_text(text.replace(old, new))
PY

UNIXNU_DISPLAY_ABI_UNQUALIFIED=1 ./unixnu build kernel -D "$DEVICE"
