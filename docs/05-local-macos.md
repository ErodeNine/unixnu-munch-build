# Building on a local macOS host

English | [简体中文](05-local-macos.zh-CN.md)

This is the local replacement for the GitHub Actions pipeline: it produces the same
`kernel.macho`, `UniXNU.efi`, `SILICIUM_UEFI.fd`, `payload.img` and `boot.img` on your
own Mac. The pipeline stays as a fallback.

## 1. Requirements

| Item | Value |
| --- | --- |
| macOS | 13 or newer; the kernel step needs an Xcode with the iOS 17 SDK |
| Xcode | 15 or newer (26.x is what CI uses); run `sudo xcode-select -s /Applications/Xcode.app` once |
| Python | 3.11 or newer (`python3 --version`) |
| Homebrew | `brew install llvm lld mtools dtc unifdef cmake ninja` |
| Disk | about 30 GB free: IPSW members 8.5 GB, build tree and kernel ~8 GB, boot image 0.2 GB |
| Time | 40–90 minutes the first time, 10–20 minutes for a rebuild with an existing `out/` |

`openssl`, `git` and `hdiutil` come with macOS. Apple Silicon and Intel both work; the script
detects the Homebrew prefix.

## 2. One command

```sh
git clone https://github.com/WuBarlynn/unixnu-munch-build
cd unixnu-munch-build
chmod +x scripts/build-local.sh
./scripts/build-local.sh ~/munch-build
```

The script:

1. clones or updates `UniXNU`, `device` and `uefi` under `~/munch-build` (the directory names are fixed: the device repository's kit symlinks resolve to `../../UniXNU/kits`);
2. applies `device/uefi/apply.sh` to the firmware checkout;
3. resolves the configuration and assembles the build tree;
4. reads the IPSW members with HTTP range requests (no 6.6 GB download);
5. builds the trust-cache bundle, the Data seed and both owner policies;
6. pins the generated Data-seed UUID into the defconfig;
7. builds kernel, package, firmware, payload and boot image.

Re-running the script is the incremental path: sources and the kernel build tree stay in
`~/munch-build/UniXNU/out`, so only what changed is rebuilt.

## 3. Manual steps

Use these when the script fails and you want to see each step.

```sh
WORK=~/munch-build
mkdir -p "$WORK" && cd "$WORK"
git clone --recurse-submodules https://github.com/FFT-infra/UniXNU.git UniXNU
git clone https://github.com/WuBarlynn/unixnu-munch.git device
git clone --recurse-submodules https://github.com/FFT-infra/uefi-alioth.git uefi

device/uefi/apply.sh "$WORK/uefi"          # installs munchPkg, config, DTB, binary overrides

cd UniXNU
./unixnu defconfig munch_defconfig -D ../device
./unixnu fetch
./unixnu status --json
./unixnu tree
```

Fetch the three IPSW members the chain needs:

```sh
./unixnu ipsw fetch OS Cryptex1,SystemOS StaticTrustCache Cryptex1,SystemTrustCache
```

Trust-cache bundle (the two original modules, one bundle):

```sh
VOL=.cache/firmware/target-volumes && mkdir -p "$VOL"
python3 ../unixnu-munch-build/scripts/prepare-trust-module.py \
  out/ipsw/21H461/044-76040-038.dmg.trustcache "$VOL/static-trustcache.bin" \
  da88460e6e513438d5307e5c526f76497a74754476a24da29f239f0c90120fc2
python3 ../unixnu-munch-build/scripts/prepare-trust-module.py \
  out/ipsw/21H461/044-76034-038.dmg.trustcache "$VOL/system-trustcache.bin" \
  d121ba89167e03aafd00fa687c30cd8ebc4ccafd10c1408adb2ba3de12403651
```

The Data seed and owner policies need the OS volume mounted:

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

Pin the seed UUID, then build:

```sh
UUID=$(python3 -c "import json;print(json.load(open('build/owner-data-fixture/seed.json'))['volume_uuid'])")
# replace CONFIG_XNU_OWNER_DATA_VOLUME_UUID in ../device/configs/munch_defconfig with $UUID
./unixnu defconfig munch_defconfig -D ../device

for d in libsa libkern osfmk bsd pexpert iokit security; do
  mkdir -p "$OUT/tree/build/xnu/ios-obj/EXPORT_HDRS/$d"
done
export UNIXNU_UEFI=$WORK/uefi

./unixnu build kernel
./unixnu build package
./unixnu build firmware --uefi "$WORK/uefi"
./unixnu build payload --unique-chip-id "$(cat ../unixnu-munch-build/config/unique-chip-id.txt)" \
  --trust-cache build/original-static-system-trust/original-static-system.bundle \
  --data-ramdisk build/owner-data-fixture/owner-data-3.dbr
./unixnu bootimg --uefi "$WORK/uefi" --dtb "$WORK/uefi/Resources/DTBs/munch.dtb"
```

## 4. Outputs

All under `out/munch/ipados-17.7.11-21H461/munch/`:

| Path | Content |
| --- | --- |
| `kernel/kernel.macho` | prelinked kernel (about 120 MB with both policies embedded) |
| `package/Build/Out/` | `UniXNU.efi`, `UniXNUDxe.efi`, `UniXNURamDiskDxe.efi` |
| `uefi` checkout `Build/munchPkg/DEBUG_CLANGPDB/FV/SILICIUM_UEFI.fd` | firmware volume |
| `payload/payload.img` | 176 MiB FAT payload |
| `boot/boot.img` | the image to test |

## 5. Rebuild and clean

- Source update: `git -C ~/munch-build/device pull` (and the same for `UniXNU`, `uefi`), then re-run the script.
- Configuration change: edit `device/board.toml` or `device/configs/munch_defconfig`, re-run; the script re-runs `defconfig` and `tree`.
- Full clean: `cd ~/munch-build/UniXNU && ./unixnu clean` (keeps fetched sources), or delete `out/` for a from-scratch build.
- Firmware volume only: run the script up to `build firmware`, then `./unixnu bootimg --uefi ... --dtb ...` again (the payload is picked from `out/.../payload/payload.img`).

## 6. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `xcodebuild: error: SDK "iphoneos" cannot be located` | Xcode not selected | `sudo xcode-select -s /Applications/Xcode.app` |
| `ld.lld: command not found` | Homebrew lld missing from PATH | `brew install lld`; the script adds `$(brew --prefix llvm)/bin` |
| `hdiutil: attach failed - Resource busy` | the OS volume is already mounted | `hdiutil detach .cache/firmware/target-volumes/os-mount -force`, re-run |
| `Require the unchanged supplied original OS mount` | the IPSW member is not 17.7.11/21H461 | check `./unixnu ipsw info` |
| `No space left on device` | less than ~10 GB free during userdata or kernel | free disk; the members can be deleted after the build |
| `EXPORT_HDRS/libsa: no such file` | the bootstrap pass stopped before exporting headers | the script pre-creates the directories; keep that step |
| `check-munch: set UNIXNU_UEFI` | firmware step without the variable | `export UNIXNU_UEFI=$WORK/uefi` |
| kernel link: `symbol(s) not found` | a stage-2 component is selected without its archive | see `docs/04-troubleshooting.md`; the script builds the stage-1 set |

## 7. What a local build does not do

- It does not build the userdata image; the inherited window geometry describes the full
  ~226 GiB partition. See `docs/04-troubleshooting.md`.
- It does not publish a release; the artifacts stay in `out/`.
- The firmware is a DEBUG build, so EDK II assertions halt instead of continuing. Pass
  `--target RELEASE` to `build package`/`build firmware` when you want a release volume.
