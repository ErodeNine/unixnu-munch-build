# unixnu-munch-build

English | [简体中文](README.zh-CN.md)

**Build repository** for the Redmi K40S / POCO F4 (`munch`, SM8250-AC) UniXNU port. It holds the GitHub Actions pipeline, the fixed inputs and every image the pipeline produces.

The device code (board.toml, DTS, defconfig, kernel archive recipes, UEFI platform) lives in a second repository:

| Repository | Role |
| --- | --- |
| [WuBarlynn/unixnu-munch](https://github.com/WuBarlynn/unixnu-munch) | **Code.** Board description, DTS, defconfig, archive recipes, `uefi/` overlay |
| [WuBarlynn/unixnu-munch-build](https://github.com/WuBarlynn/unixnu-munch-build) | **Build** (this repository). `build.yml`, fixed inputs, logs and image releases |
| [FFT-infra/UniXNU](https://github.com/FFT-infra/UniXNU) | Build driver `./unixnu`, component catalog, ARM64/OS profiles (fork with `QcomXnuUsbDebug` and the SM8250 work) |
| [FFT-infra/uefi-alioth](https://github.com/FFT-infra/uefi-alioth) | Mu-Silicium base firmware: UniXNU app, RamDisk driver, DarwinBoot, SM8250 platform includes |
| [FFT-infra/UniXNU-sm8250-common](https://github.com/FFT-infra/UniXNU-sm8250-common) | SM8250/SM8250-AC resources, DTSI, kernel config fragment |

## How the two repositories connect

```
push to unixnu-munch (main)
        │
        ▼
GitHub Actions: manual dispatch or tag
        │
        ├── checkout this repository  → pipeline, config/unique-chip-id.txt
        ├── checkout unixnu-munch     → device/
        ├── checkout UniXNU           → UniXNU/
        └── checkout uefi-alioth      → uefi/ + device/uefi/apply.sh overlay
        │
        ▼
kernel → package → firmware → payload → boot.img → release
```

- The pipeline always pulls `WuBarlynn/unixnu-munch@main`. Change `env.DEVICE_REF` in `build.yml` to build another branch or tag.
- `device/uefi/apply.sh` installs `munchPkg`, `Resources/Configs/munch.toml`, `Resources/DTBs/munch.dts` and the ACPI package onto `uefi-alioth`, and compiles `munch.dtb`.
- No personal access token is required: only the default `GITHUB_TOKEN` reads public repositories.
- `config/unique-chip-id.txt` is the platform seed. Keep it stable; changing it is equivalent to replacing the device.

## Triggering a build

1. Open **Actions → build-munch → Run workflow**.
2. `steps` defaults to `all`:
   - `kernel`: kernel only (fastest, validates the toolchain).
   - `kernel-payload`: kernel + payload.
   - `boot-image`: pack `boot.img` from existing outputs.
   - `all`: kernel, payload, UEFI firmware and `boot.img`.
3. `userdata` is off by default: the userdata image needs about 20 GB of free disk, which the hosted macOS runner may not have. Use a self-hosted runner when you need it.
4. `release` defaults to on; images are attached to a `build-<run_number>` release.

Tag pushes build and release automatically:

```sh
git tag v0.1 && git push origin v0.1
```

## Latest successful build

Run 18 (tag `v0.18`) completed every step: kernel, package, firmware, payload and boot image.

| Asset | Size | Use |
| --- | --- | --- |
| `boot.img` | 178.4 MB | `fastboot boot boot.img` (non-destructive) |
| `payload.img` | 176.0 MB | contained in `boot.img` |
| `kernel.macho` | 120.1 MB | prelinked kernel with both VerifiedRoot manifests embedded |
| `boot.json` / `payload.json` / `status.json` | small | build reports |

`SILICIUM_UEFI.fd` is embedded in `boot.img`; later runs also publish it as its own asset.

`userdata` is **not** part of the release. The window geometry inherited from the
SM8250 reference describes the full userdata partition (about 226 GiB), so the raw
image cannot be shipped as a release asset. Stage C in the test manual therefore needs
either a locally built sparse image, or a repartitioned/shrunk userdata, before it can
run.

## Outputs

| File | Path inside the release | Purpose |
| --- | --- | --- |
| `boot.img` | `out/munch/ipados-17.7.11-21H461/munch_defconfig/boot/boot.img` | one-shot boot: `fastboot boot boot.img` |
| `SILICIUM_UEFI.fd` | `.../firmware/` | UEFI firmware volume with UniXNU and DarwinBoot |
| `payload.img` | `.../payload/` | FAT payload: unixnu.toml, kernel.macho, ADT, trust cache, Data seed |
| `kernel.macho` / `.adt` | `.../kernel/` | prelinked kernel and its Apple device-tree sidecar |
| `userdata-root.img` | `.../userdata/` | only when `userdata=true` |
| `*.log`, `status.json` | `.../logs/`, release root | build record and resolved dependency graph |

> **Legal notice.** `kernel.macho`, `payload.img`, `boot.img` and `userdata-root.img` contain material derived from Apple's IPSW (kernelcache, trust cache, OS images). Keep this repository **private** and do not redistribute those files.

## Local reproduction

```sh
git clone --recurse-submodules https://github.com/FFT-infra/UniXNU
git clone https://github.com/WuBarlynn/unixnu-munch
git clone --recurse-submodules https://github.com/FFT-infra/uefi-alioth

unixnu-munch/uefi/apply.sh "$PWD/uefi-alioth"

cd UniXNU
./unixnu defconfig munch_defconfig -D ../unixnu-munch
./unixnu fetch && ./unixnu tree
./unixnu build kernel
./unixnu build package
./unixnu build firmware --uefi ../uefi-alioth
./unixnu build payload --unique-chip-id 7248a912881f43a1 \
    --trust-cache build/original-static-system-trust/original-static-system.bundle \
    --data-ramdisk build/owner-data-fixture/owner-data-3.dbr
./unixnu bootimg --uefi ../uefi-alioth --dtb ../uefi-alioth/Resources/DTBs/munch.dtb
```

`build-original-system-trust.py` and `prepare-owner-data-fixture.py` run only on macOS. Linux can do kernel (after `scripts/linux/setup-toolchain.py`), package, firmware and boot image.

## Documentation

| Document | Contents |
| --- | --- |
| [docs/01-feasibility.md](docs/01-feasibility.md) | Feasibility: evidence, blockers, conclusion |
| [docs/02-porting-plan.md](docs/02-porting-plan.md) | The eight official porting steps and how this port fills them |
| [docs/03-real-device-test.md](docs/03-real-device-test.md) | Step-by-step hardware test: unlock, backup, flash, logs, rollback |
| [docs/04-troubleshooting.md](docs/04-troubleshooting.md) | Known limits and failure branches |
| [docs/05-local-macos.md](docs/05-local-macos.md) | Build every image on a local Mac (`scripts/build-local.sh`) |

Every document has a Simplified Chinese version at `<name>.zh-CN.md`.
