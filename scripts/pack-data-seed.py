#!/usr/bin/env python3
"""Pack a raw APFS Data seed into the DBRDISK1 form the kernel reads.

prepare-owner-data-fixture.py writes a raw 32 MiB APFS container
(owner-data-32.cdr); seed-data-grow.py requires an already packed seed. Pack
here, then grow.

Run from the UniXNU checkout:
  python3 ../scripts/pack-data-seed.py build/owner-data-fixture/owner-data-32.cdr \
      build/owner-data-fixture/owner-data-32.dbr
"""
import sys
from pathlib import Path

ROOT = Path.cwd()
sys.path.insert(0, str(ROOT / 'drivers/DarwinBoot/Test'))
import packed_ramdisk  # noqa: E402


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    source, target = Path(sys.argv[1]), Path(sys.argv[2])
    if target.exists():
        raise SystemExit(f'refuse to overwrite {target}')
    metadata = packed_ramdisk.pack(source, target)
    print(f'{target}: {target.stat().st_size} bytes {metadata}')


if __name__ == '__main__':
    main()
